import PorpoiseFileSystem

// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz
import SwiftTerm

/// Test hook: lets scripts ask the running app for a window snapshot or its state, and trigger actions,
/// via distributed notifications. Used by scripts/uitest.sh. Inert unless someone posts to it.
@MainActor final class DebugBridge: NSObject {
    static let shared = DebugBridge()
    var transferPreviewJob: FileJob?
    /// The channel; PORPOISE_BRIDGE gives a test instance its own, so parallel test runs don't hear each other.
    static let request = Notification.Name("app.porpoise.Porpoise.debug." + (TestEnvironment.bridge.value() ?? "test"))

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handle(_:)), name: Self.request, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    /// The Settings window (its title follows the page shown).
    var settingsWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.windowController is SettingsWindowController } }

    var wc: MainWindowController? {
        if let i = targetWindow, AppDelegate.shared.windows.indices.contains(i) { return AppDelegate.shared.windows[i] }
        return (NSApp.keyWindow?.windowController as? MainWindowController) ?? AppDelegate.shared.windows.first
    }
    /// The browser window commands act on, set by `frontwindow` (a test instance in the background has no key window).
    var targetWindow: Int?

    /// A command: what the bridge does with the rest of the line after its name.
    typealias Command = @MainActor (DebugBridge) -> @MainActor (String) -> Void

    /// Every command by its first word, from the tables of the domain extensions.
    private static let commands = [
        stateCommands, captureCommands, inputCommands, columnCommands, placesCommands, settingsCommands, transfersCommands, cloudCommands,
        workspaceCommands,
    ].reduce(into: [String: Command]()) { all, table in
        all.merge(table) { first, _ in
            assertionFailure("two bridge commands share a name"); return first
        }
    }

    @objc nonisolated private func handle(_ n: Notification) {
        guard let line = n.object as? String else { return }
        receive(line)
    }

    /// Distributed notifications can enter from another thread. Decode only Sendable data before the UI hop.
    nonisolated func receive(_ line: String) {
        MainActorDelivery.deliver { [weak self] in self?.execute(line) }
    }

    private func execute(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first, let command = Self.commands[name] else { return }
        command(self)(parts.count > 1 ? parts[1] : "")
    }

    /// What the app shows and holds: state, menus, settings and windows, as files.
    static let stateCommands: [String: Command] = [
        "termtext": DebugBridge.termtextCommand,
        "state": DebugBridge.writeState(to:),
        "onboarding": DebugBridge.onboardingCommand,
        "rtest": DebugBridge.remoteTest(_:),
        "menus": DebugBridge.menusCommand,
        "hamburger": DebugBridge.hamburgerCommand,
        "commandcatalog": DebugBridge.commandcatalogCommand,
        "settingsdump": DebugBridge.settingsdumpCommand,
        "permissions": DebugBridge.permissionsCommand,
        "windows": DebugBridge.windowsCommand,
        "session": DebugBridge.sessionCommand,
        "splitfraction": DebugBridge.splitfractionCommand,
        "frontwindow": DebugBridge.frontwindowCommand,
        "winframe": DebugBridge.winframeCommand,
        "contentsize": DebugBridge.contentsizeCommand,
        "fka": DebugBridge.fkaCommand,
        "focus": DebugBridge.focusCommand,
        "keymenu": DebugBridge.keymenuCommand,
    ]

    func termtextCommand(_ arg: String) {
        if let w = wc {
            try? (w.terminal.terminalView.getTerminal().getText(start: Position(col: 0, row: 0), end: Position(col: 200, row: 40))).write(
                toFile: arg, atomically: true, encoding: .utf8)
        }
    }

    func onboardingCommand(_ arg: String) {
        try? "\(OnboardingWindowController.debugStep) windows=\(AppDelegate.shared.windows.count)".write(
            toFile: arg, atomically: true, encoding: .utf8)
    }

    func menusCommand(_ arg: String) {
        if let m = NSApp.mainMenu { dumpMenu(m, to: arg) }
    }

    /// hamburger <file>: the toolbar's hamburger menu, like `menus`.
    func hamburgerCommand(_ arg: String) {
        if let w = wc { dumpMenu(w.hamburgerMenu(), to: arg) }
    }

    func commandcatalogCommand(_ arg: String) {
        MenuCommandRegistry.shared.refresh()
        let registry = MenuCommandRegistry.shared
        let actions = registry.commands.map { command -> [String: Any] in
            [
                "id": command.id, "title": command.path, "key": command.item.keyEquivalent,
                "modifiers": ShortcutModifiers(command.item.keyEquivalentModifierMask).rawValue,
            ]
        }
        let report: [String: Any] = [
            "actions": actions, "conflicts": Settings.shared.keyboardShortcuts.conflicts(actions: registry.commands.map(\.definition)).count,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: arg))
        }
    }

    /// settingsdump <file>: every control of the Settings window, page by page, with value and enabled state.
    func settingsdumpCommand(_ arg: String) {
        dumpSettings(to: arg)
    }

    /// permissions <step> [granted|waiting|skip]: the welcome sheet at welcome or fullDisk, on the front window; `granted` or
    /// `waiting` shows Full Disk Access as on or off (for screenshots), `skip` clicks Not Now.
    func permissionsCommand(_ arg: String) {
        let words = arg.split(separator: " ").map(String.init)
        let step = OnboardingWindowController.Step.allCases.first { "\($0)" == words.first } ?? .welcome
        if words.contains("granted") { OnboardingWindowController.fullDiskGranted = { true } }
        if words.contains("waiting") { OnboardingWindowController.fullDiskGranted = { false } }
        if words.contains("skip") { OnboardingWindowController.shared?.finish(); return }
        OnboardingWindowController.show(at: step, on: wc?.window)
    }

    /// fka on|off: Full Keyboard Access as this instance sees it (the system setting otherwise).
    func fkaCommand(_ arg: String) {
        let on = arg == "on"
        KeyboardAccess.isFull = arg == "system" ? { NSApp.isFullKeyboardAccessEnabled } : { on }
    }

    /// keymenu <png>: presses ⇧F10 in the list, captures the menu it opens (and its items to <png>.txt), then closes it.
    func keymenuCommand(_ arg: String) {
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            WindowCapture.write(WindowCapture.ownWindowIDs(), to: arg)
            let menu = ItemListView.keyboardMenuShown
            let items = menu?.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title) ?? []
            try? (["open=\(menu != nil)"] + items).joined(separator: "\n").write(toFile: arg + ".txt", atomically: true, encoding: .utf8)
            menu?.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.async { self.sendKey("shift+f10") }
    }

    /// focus <file>: appends the focused view (and its accessibility label) to the file, one line per call.
    func focusCommand(_ arg: String) {
        let r = wc?.window?.firstResponder
        let view = MainWindowController.focusedView(r)
        var line = view.map { String(describing: type(of: $0)) } ?? r.map { String(describing: type(of: $0)) } ?? "nil"
        if let label = view?.accessibilityLabel(), !label.isEmpty { line += " \"\(label)\"" }
        let url = URL(fileURLWithPath: arg)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func windowsCommand(_ arg: String) {
        // The controller's own class (MainWindowController, SettingsWindowController…), not the declared Optional.
        let list = NSApp.windows.filter(\.isVisible).map { w in
            "\(w.title)|\(w.windowController.map { String(describing: type(of: $0)) } ?? "-")|key=\(w.isKeyWindow)"
        }
        try? list.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
    }

    /// session <file>: the windows as the session keeps them now ("live"), as last saved ("saved"), as each window
    /// was when it first appeared ("firstShown"), and whether a restore is still settling, as JSON.
    func sessionCommand(_ arg: String) {
        let app = AppDelegate.shared
        let report: [String: Any] = [
            "live": SessionState(windows: app.windows.map { $0.captureLayout() }).json,
            "saved": SessionState(stored: Settings.store.object(forKey: SessionState.key)).json,
            "firstShown": SessionState(windows: app.firstShown).json,
            "restoring": Settings.store.bool(forKey: AppDelegate.restoringKey),
            "windowCount": app.windows.count,
            "messages": app.windows.map { $0.view.messageBar.isHidden ? "" : $0.view.messageBar.text },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: arg))
        }
    }

    /// splitfraction <0…1>: moves the current tab's split handle there, as a drag does.
    func splitfractionCommand(_ arg: String) {
        if let w = wc, let f = Double(arg) { w.tab.setSplitShare(CGFloat(f)) }
    }

    /// frontwindow <index>: brings that browser window (in the order they were opened) to the front, and makes it the
    /// one later commands act on.
    func frontwindowCommand(_ arg: String) {
        guard let i = Int(arg), AppDelegate.shared.windows.indices.contains(i) else { return }
        targetWindow = i
        AppDelegate.shared.windows[i].window?.makeKeyAndOrderFront(nil)
    }

    /// winframe <x> <y> <width> <height>: the window's frame, in screen coordinates.
    func winframeCommand(_ arg: String) {
        let n = arg.split(separator: " ").compactMap { Double($0) }
        if n.count == 4 { wc?.window?.setFrame(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), display: true) }
    }

    /// contentsize <width|min> <height|min> <title prefix>: sizes that window's content (captures at a window's minimum).
    func contentsizeCommand(_ arg: String) {
        let parts = arg.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let w = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix(parts[2]) }) else { return }
        let content = w.contentRect(forFrameRect: w.frame).size
        let least = NSSize(
            width: max(w.contentMinSize.width, w.contentRect(forFrameRect: CGRect(origin: .zero, size: w.minSize)).width),
            height: max(w.contentMinSize.height, w.contentRect(forFrameRect: CGRect(origin: .zero, size: w.minSize)).height))
        func value(_ s: String, _ min: CGFloat, _ now: CGFloat) -> CGFloat { s == "min" ? min : Double(s).map { CGFloat($0) } ?? now }
        w.setContentSize(NSSize(width: value(parts[0], least.width, content.width), height: value(parts[1], least.height, content.height)))
    }

    func writeState(to path: String) {
        guard let w = wc else { return }
        let v = w.view
        let state: [String: Any] = [
            "toolbarCommands": Settings.shared.toolbarCommands.map(\.rawValue),
            "theme": Settings.shared.appearancePreferences.themeName,
            "iconTheme": Settings.shared.appearancePreferences.iconTheme,
            "url": v.url.isFileURL ? v.url.path : v.url.absoluteString,
            "mode": v.model.props.mode.rawValue,
            "zoom": v.model.props.zoomLevel(for: v.model.props.mode),
            "showHidden": v.model.props.showHidden,
            "rows": v.model.rows.map(\.item.name),
            "selection": v.model.selectedItems.map(\.name),
            "current": v.model.currentURL?.lastPathComponent ?? "",
            "tabs": w.tabs.map(\.title),
            "currentTab": w.current,
            "split": w.tab.isSplit,
            "linked": w.tab.linkedRoots != nil,
            "missingCounterpart": w.tab.missingCounterpart != nil,
            "activeIsSecondary": w.tab.activeIsSecondary,
            "filterVisible": !v.filterBar.isHidden,
            "searchVisible": !v.searchBar.isHidden,
            "status": v.statusBar.displayText,
            "panels": [
                "places": w.showPlaces, "folders": w.showFolders, "info": w.showInformation, "terminal": w.showTerminal, "shelf": w.showShelf,
            ],
            "terminalCwd": w.showTerminal ? (w.terminal.currentDirectory ?? "") : "",
            "terminalAlpha": w.terminal.terminalView.alphaValue,
            "ffmpegPath": VideoPreview.ffmpeg ?? "",
            "lastSound": FinderSound.lastPlayed,
            "appsAnimation": v.apps?.grid.animationInfo ?? "none",
            "tccAllFiles": PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAllFiles") ?? -1,
            "tccAppBundles": PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles") ?? -1,
            "firstResponder": w.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
            "windowTitle": w.window?.title ?? "",
            "canUndo": FileOperationsController.shared.canUndo,
            "selectionMode": w.view.selectionMode,
            "selectionPrompt": w.view.selectionMode ? w.view.selectionTop.prompt ?? "" : "",
            "splitFrames": w.debugSplitFrames,
            "scrollY": w.view.list.visibleRect.minY,
            "infoPlayer": w.showInformation ? w.information.playerDebug : "",
            "groups": v.model.groups.map(\.title),
            "breadcrumbEditing": w.tab.navigators[0].isEditing,
            "renaming": v.list.isRenaming,
            "quickLookVisible": w.spacePreview?.isVisible == true,
            "previewState": w.spacePreview?.state ?? "closed",
            "previewWindowNumber": w.spacePreview?.windowNumber ?? 0,
            "previewWindowAlpha": w.spacePreview?.alphaValue ?? 0,
            "previewCodeLines": w.spacePreview?.code.document?.displayedLines ?? 0,
            "previewCodeLimited": w.spacePreview?.code.document?.truncated ?? false,
            "previewLoadMS": w.spacePreview?.code.loadMilliseconds ?? 0,
            "previewApplyMS": w.spacePreview?.code.applyMilliseconds ?? 0,
            "keyWindowTitle": NSApp.keyWindow?.title ?? "",
            "locationText": (w.window?.firstResponder as? NSTextView)?.string ?? "",
            "windowFrame": w.window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
            "screenHeight": NSScreen.screens.first?.frame.height ?? 0,
            "isKey": w.window?.isKeyWindow ?? false,
            "appHidden": NSApp.isHidden,
            "windowVisible": w.window?.isVisible ?? false, "windowMiniaturized": w.window?.isMiniaturized ?? false,
            "windowOccluded": w.window.map { !$0.occlusionState.contains(.visible) } ?? true,
            "appActive": NSApp.isActive,
            "activationPolicy": NSApp.activationPolicy().rawValue,
            "places": PlacesModel.shared.userEntries.map(\.title),
            "detailsRoles": v.list.detailsRoles.map(\.rawValue),
            "columnWidths": Dictionary(uniqueKeysWithValues: v.list.columnWidths.map { ($0.key.rawValue, Double($0.value)) }),
            "iconSize": Double(v.list.iconSize),
            "message": v.messageBar.isHidden ? "" : v.messageBar.text,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Exercises a remote provider end to end: "rtest <folder-url>|<report-file>".
    func remoteTest(_ arg: String) {
        let parts = arg.components(separatedBy: "|")
        guard parts.count == 2, let base = URL(string: parts[0]), let p = RemoteFS.provider(for: base) else { return }
        let report = parts[1]
        DispatchQueue.global().async {
            var log: [String] = []
            func step(_ name: String, _ f: () throws -> String) {
                do { log.append("OK   \(name): \(try f())") } catch { log.append("FAIL \(name): \(error.localizedDescription)") }
            }
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("porpoise-rtest-\(getpid())")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let local = tmp.appendingPathComponent("up load.txt")
            try? "hello remote\n".write(to: local, atomically: true, encoding: .utf8)
            let localDir = tmp.appendingPathComponent("updir")
            try? FileManager.default.createDirectory(at: localDir.appendingPathComponent("inner"), withIntermediateDirectories: true)
            try? "x".write(to: localDir.appendingPathComponent("inner/a.txt"), atomically: true, encoding: .utf8)
            let work = base.appendingPathComponent("rtest work", isDirectory: true)
            step("list root") {
                try p.list(base).map { "\($0.name)\($0.isDirectory ? "/" : "")\($0.isSymlink ? "@" : "")" }.sorted().joined(separator: " ")
            }
            step("mkdir") {
                try p.makeFolder(work); return "made"
            }
            step("upload file") {
                try p.upload(local, into: work); return "done"
            }
            step("upload folder") {
                try p.upload(localDir, into: work); return "done"
            }
            step("list work") { try p.list(work).map { "\($0.name):\($0.size)" }.sorted().joined(separator: " ") }
            step("rename") {
                try p.rename(work.appendingPathComponent("up load.txt"), to: "renamed file.txt"); return "done"
            }
            step("copy") {
                try p.copy([work.appendingPathComponent("renamed file.txt")], into: work.appendingPathComponent("updir", isDirectory: true));
                return "done"
            }
            step("move") {
                try p.move([work.appendingPathComponent("renamed file.txt")], into: work.appendingPathComponent("updir/inner", isDirectory: true));
                return "done"
            }
            step("list updir") { try p.list(work.appendingPathComponent("updir", isDirectory: true)).map(\.name).sorted().joined(separator: " ") }
            step("list inner") {
                try p.list(work.appendingPathComponent("updir/inner", isDirectory: true)).map(\.name).sorted().joined(separator: " ")
            }
            step("download file") {
                let d = try p.download(
                    work.appendingPathComponent("updir/inner/renamed file.txt"), into: tmp.appendingPathComponent("dl", isDirectory: true))
                return (try? String(contentsOf: d, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unreadable"
            }
            step("download folder") {
                let d = try p.download(
                    work.appendingPathComponent("updir", isDirectory: true), into: tmp.appendingPathComponent("dl2", isDirectory: true))
                return (FileManager.default.subpaths(atPath: d.path) ?? []).sorted().joined(separator: " ")
            }
            step("delete") {
                try p.delete([work]); return "done"
            }
            step("list after delete") { try p.list(base).map(\.name).sorted().joined(separator: " ") }
            try? FileManager.default.removeItem(at: tmp)
            try? log.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
    }

    /// An item's enabled state after validation. Without a key window (a test instance in the background) AppKit
    /// disables every window action, so the window controller is asked directly, as the responder chain would.
    func isEnabled(_ it: NSMenuItem) -> Bool {
        if NSApp.keyWindow == nil, it.target == nil, let a = it.action, let w = wc, w.responds(to: a) { return w.validateMenuItem(it) }
        return it.isEnabled
    }

    /// Every item of a menu (and its submenus) with its shortcut and enabled state (after validation).
    func dumpMenu(_ menu: NSMenu, to path: String) {
        var out: [String] = []
        @MainActor func walk(_ m: NSMenu, _ prefix: String) {
            m.delegate?.menuNeedsUpdate?(m)  // as when the menu opens (dynamic submenus fill themselves)
            m.update()
            for it in m.items where !it.isSeparatorItem {
                var k = it.keyEquivalent
                if let c = k.unicodeScalars.first, c.value >= 0xF700 {
                    let names: [UInt32: String] = [0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0xF728: "⌦", 0xF729: "Home", 0xF72B: "End"]
                    k = names[c.value] ?? (c.value >= 0xF704 && c.value <= 0xF726 ? "F\(Int(c.value) - 0xF703)" : "?")
                }
                if k == "\u{8}" || k == "\u{7f}" { k = "⌫" }
                if k == "\r" { k = "↩" }
                if k == "\t" { k = "⇥" }
                let mods = it.keyEquivalentModifierMask
                let ks =
                    k.isEmpty
                    ? ""
                    : (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "")
                        + (mods.contains(.command) ? "⌘" : "") + k
                out.append(
                    "\(prefix)\(it.title)\t\(ks)\t\(isEnabled(it) ? "" : "disabled")\(it.isHidden ? " hidden" : "")\(it.isAlternate ? " alt" : "")")
                if let sm = it.submenu { walk(sm, prefix + "  ") }
            }
        }
        walk(menu, "")
        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The Settings window's controls: "[page]" headers, then one line per checkbox/radio/popup/field/button.
    func dumpSettings(to path: String) {
        guard let tabs = settingsWindow?.contentViewController as? NSTabViewController else { return }
        var out: [String] = []
        @MainActor func walk(_ v: NSView) {
            let off = (v as? NSControl).map { $0.isEnabled ? "" : " (disabled)" } ?? ""
            switch v {
            case let p as NSPopUpButton: out.append("  popup: \(p.titleOfSelectedItem ?? "")\(off)")
            case let b as NSButton:
                let isToggle = (b as? ClosureButton)?.isToggle == true
                out.append(isToggle ? "  [\(b.state == .on ? "x" : " ")] \(b.title)\(off)" : "  button: \(b.title)\(off)")
            case let t as NSTextField:
                if t.isEditable {
                    out.append("  field: \(t.stringValue)\(off)")
                } else if t.textColor == .disabledControlTextColor {
                    out.append("  label (disabled): \(t.stringValue)")
                }
            default: break
            }
            if !(v is NSControl) { v.subviews.forEach(walk) }
        }
        for item in tabs.tabViewItems {
            let scroll = item.viewController?.view as? NSScrollView
            let size = { (r: CGRect?) in r.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?" }
            out.append("[\(item.label)] document \(size(scroll?.documentView?.frame)) visible \(size(scroll?.contentView.bounds))")
            if let v = item.viewController?.view { walk(v) }
        }
        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

}

#endif
