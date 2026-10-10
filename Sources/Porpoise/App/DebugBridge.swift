import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz
import SwiftTerm

/// Test hook: lets scripts ask the running app for a window snapshot or its state, and trigger actions,
/// via distributed notifications. Used by scripts/uitest.sh. Inert unless someone posts to it.
final class DebugBridge: NSObject {
    static let shared = DebugBridge()
    /// The channel; PORPOISE_BRIDGE gives a test instance its own, so parallel test runs don't hear each other.
    static let request = Notification.Name("app.porpoise.Porpoise.debug." + (ProcessInfo.processInfo.environment["PORPOISE_BRIDGE"] ?? "test"))

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handle(_:)), name: Self.request, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    /// The Settings window (its title follows the page shown).
    private var settingsWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.windowController is SettingsWindowController } }

    private var wc: MainWindowController? {
        (NSApp.keyWindow?.windowController as? MainWindowController) ?? AppDelegate.shared.windows.first
    }

    @objc private func handle(_ n: Notification) {
        guard let cmd = n.object as? String else { return }
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "snapshot": snapshot(to: arg)
        case "lsnapshot": layerSnapshot(to: arg)
        case "wsnapshot": windowServerSnapshot(to: arg)
        case "wframes":
            // wframes <folder> <count> <ms>: the main window every <ms> milliseconds, as 00.png, 01.png… (animations).
            let a = arg.split(separator: " ").map(String.init)
            guard a.count == 3, let n = Int(a[1]), let ms = Int(a[2]) else { return }
            try? FileManager.default.createDirectory(atPath: a[0], withIntermediateDirectories: true)
            for k in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(k * ms)) { [weak self] in
                    self?.windowServerSnapshot(to: a[0] + String(format: "/%02d.png", k))
                }
            }
        case "csnapshot":
            // csnapshot <png>|<title prefix or "Settings">: draws a window's views itself, so it works while the window
            // is inactive or shrunk by Stage Manager (no window-server capture).
            let parts = arg.components(separatedBy: "|")
            guard parts.count == 2 else { return }
            let w = parts[1] == "Settings" ? settingsWindow : NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(parts[1]) }
            if let fv = w?.contentView?.superview, let rep = fv.bitmapImageRepForCachingDisplay(in: fv.bounds) {
                fv.cacheDisplay(in: fv.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[0]))
            }
        case "winsize":
            // winsize <width> <height>: the main window's size in points, centred (for screenshots).
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, let win = wc?.window {
                win.setFrame(CGRect(x: 0, y: 0, width: n[0], height: n[1]), display: true)
                win.center()
            }
        case "panel":
            if let w = wc {
                let tag = ["places": 0, "info": 1, "folders": 2, "terminal": 3][arg] ?? 3
                let it = NSMenuItem(); it.tag = tag
                w.togglePanel(it)
            }
        case "mode":
            if let w = wc, let m = ViewMode(rawValue: arg) { w.view.setMode(m); w.syncToActiveView() }
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderedWindows.first { $0.windowController is MainWindowController }?.makeKeyAndOrderFront(nil)
        case "keysnapshot":
            if let w = NSApp.keyWindow, let fv = w.contentView?.superview, let rep = fv.bitmapImageRepForCachingDisplay(in: fv.bounds) {
                fv.cacheDisplay(in: fv.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
        case "termsnap":
            if let t = wc?.terminal.terminalView, let rep = t.bitmapImageRepForCachingDisplay(in: t.bounds) {
                t.cacheDisplay(in: t.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                let info =
                    "frame=\(t.frame) superFrame=\(t.superview?.frame ?? .zero) hidden=\(t.isHidden) bg=\(t.nativeBackgroundColor) layerBg=\(String(describing: t.layer?.backgroundColor))"
                try? info.write(toFile: arg + ".txt", atomically: true, encoding: .utf8)
            }
        case "termtext":
            if let w = wc {
                try? (w.terminal.terminalView.getTerminal().getText(start: Position(col: 0, row: 0), end: Position(col: 200, row: 40))).write(
                    toFile: arg, atomically: true, encoding: .utf8)
            }
        case "state": writeState(to: arg)
        case "onboarding":
            try? "\(OnboardingWindowController.debugStep) windows=\(AppDelegate.shared.windows.count)".write(
                toFile: arg, atomically: true, encoding: .utf8)
        case "rtest": remoteTest(arg)
        case "menus": if let m = NSApp.mainMenu { dumpMenu(m, to: arg) }
        case "hamburger":
            // hamburger <file>: the toolbar's hamburger menu, like `menus`.
            if let w = wc { dumpMenu(w.hamburgerMenu(), to: arg) }
        case "click":
            // click <window title prefix or "Settings">|<button title, or popup#N for the Nth popup>[|<popup item>]:
            // clicks a button/checkbox, or picks a popup item, in any window of the app (no real mouse).
            let p = arg.components(separatedBy: "|")
            // "Sheet" is the open sheet or alert (they have no title).
            let window =
                p[0] == "Settings"
                ? settingsWindow
                : p[0] == "Sheet"
                    ? NSApp.windows.first { $0.isVisible && ($0.isSheet || $0.isModalPanel || $0.level == .modalPanel) }
                    : NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(p[0]) }
            guard p.count >= 2, let root = window?.contentView else { return }
            var popups: [NSPopUpButton] = []
            var button: NSButton?
            func walk(_ v: NSView) {
                if let pop = v as? NSPopUpButton {
                    popups.append(pop)
                } else if let seg = v as? NSSegmentedControl,
                    let i = (0..<seg.segmentCount).first(where: { seg.label(forSegment: $0) == p[1] })
                {
                    seg.selectedSegment = i
                    if let a = seg.action { NSApp.sendAction(a, to: seg.target, from: seg) }
                } else if let b = v as? NSButton, b.title == p[1], button == nil {
                    button = b
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            if p[1].hasPrefix("popup#"), let i = Int(p[1].dropFirst(6)), let pop = popups[safe: i], p.count == 3 {
                pop.selectItem(withTitle: p[2])
                if let a = pop.action { NSApp.sendAction(a, to: pop.target, from: pop) }
            } else if p[1] == "popups", p.count == 3 {
                // click <window>|popups|<file>: each popup's items, the selected one starred, one popup per line.
                let out = popups.map { pop in pop.itemTitles.map { $0 == pop.titleOfSelectedItem ? "*" + $0 : $0 }.joined(separator: ", ") }
                try? out.joined(separator: "\n").write(toFile: p[2], atomically: true, encoding: .utf8)
            } else {
                button?.performClick(nil)
            }
        case "settingsdump":
            // settingsdump <file>: every control of the Settings window, page by page, with value and enabled state.
            dumpSettings(to: arg)
        case "tag": wc?.toggleTag(arg)
        case "hover": if let v = wc?.view { v.list.hoverIndex = v.model.rows.firstIndex { $0.item.name == arg } }
        case "sectionmove":
            // sectionmove <section>|<before section or empty>
            let p = arg.components(separatedBy: "|")
            if p.count == 2, let s = PlaceSection(rawValue: p[0]) { PlacesModel.shared.moveSection(s, before: PlaceSection(rawValue: p[1])) }
        case "placeslock": PlacesModel.shared.isLocked = arg == "on"
        case "placesclick":
            // placesclick <title>[|eject]: clicks a Places row (or its eject button) with synthesized events.
            let parts = arg.components(separatedBy: "|")
            guard let w = wc, let win = w.window, let r = w.places.rowRect(title: parts[0]) else { return }
            w.places.scrollToVisible(r)  // as a user would scroll to it
            w.window?.displayIfNeeded()
            let local = parts.count > 1 ? CGPoint(x: r.maxX - 26, y: r.minY + 14) : CGPoint(x: 40, y: r.midY)
            let p = w.places.convert(local, to: nil)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(
                    with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                {
                    win.sendEvent(e)
                }
            }
        case "permissions":
            // permissions <step>: welcome, fullDisk, apps, admin, network or done.
            let step = OnboardingWindowController.Step.allCases.first { "\($0)" == arg } ?? .welcome
            OnboardingWindowController.show(at: step)
        case "appmgmt":
            SystemIntegration.requestAppManagement {
                try? "\(PrivacyAccess.appManagementState)".write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "scrollto": if let y = Double(arg) { wc?.view.list.scroll(CGPoint(x: 0, y: y)) }
        case "pinch":
            // pinch <factor>: a pinch at the middle of the visible area, released (committed) like a real gesture.
            guard let l = wc?.view.list, let f = Double(arg) else { return }
            let vr = l.visibleRect
            l.previewZoom(l.iconSize * CGFloat(f), anchor: CGPoint(x: vr.midX, y: vr.midY), commitAfter: 0)
        case "dragpb":
            // Writes the selection the way a drag does, to a private pasteboard, and reports what other apps would read.
            guard let w = wc else { return }
            let urls = w.view.model.selectedItems.map(\.url)
            let pb = NSPasteboard(name: NSPasteboard.Name("app.porpoise.Porpoise.dragtest"))
            pb.clearContents()
            pb.writeObjects(urls.enumerated().map { FileDragWriter(url: $0.element, allURLs: $0.offset == 0 ? urls : nil) })
            let legacy = pb.propertyList(forType: FileDragWriter.filenames) as? [String] ?? []
            let modern = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(\.path) ?? []
            let out = "types=\(pb.types?.map(\.rawValue) ?? [])\nlegacy=\(legacy)\nmodern=\(modern)"
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
            pb.releaseGlobally()
        case "droponto":
            // droponto <folder>: drops the selection on a folder, as a drag with the move operation would.
            guard let w = wc else { return }
            FileOperationsController.shared.handleDrop(
                w.view.model.selectedItems.map(\.url), onto: URL(fileURLWithPath: arg),
                operation: .move, in: w.view)
        case "placesmove":
            // placesmove <title>|<before title or empty>|<section raw>
            let p = arg.components(separatedBy: "|")
            let all = PlacesModel.shared.allEntries
            guard p.count == 3, let e = all.first(where: { $0.title == p[0] }), let sec = PlaceSection(rawValue: p[2]) else { return }
            PlacesModel.shared.move(e, before: all.first { $0.title == p[1] }, endOf: sec)
        case "places":
            let lines = PlacesModel.shared.sections().map { "\($0.0.rawValue): " + $0.1.map(\.title).joined(separator: ", ") }
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "rename":
            // rename <path>|<new name>, through the normal rename path (async so the bridge returns).
            let p = arg.components(separatedBy: "|")
            guard p.count == 2, let w = wc, let it = FileItem.load(URL(fileURLWithPath: p[0])) else { return }
            DispatchQueue.main.async { w.rename(it, to: p[1], in: w.view) }
        case "cloudclick":
            // Clicks the cloud badge of the named item with a synthesized event (inside the app only).
            guard let w = wc, let i = w.view.model.rows.firstIndex(where: { $0.item.name == arg }), let r = w.view.list.cloudRects[i],
                let win = w.window
            else { return }
            let p = w.view.list.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(
                    with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                {
                    win.sendEvent(e)
                }
            }
        case "menu":
            // menu Go/Desktop: performs a main-menu item by its titles (after validation).
            var m = NSApp.mainMenu
            let path = arg.split(separator: "/").map(String.init)
            for (i, t) in path.enumerated() {
                guard let menu = m else { break }
                menu.update()
                guard let idx = menu.items.firstIndex(where: { $0.title == t && !$0.isHidden }) else { NSLog("DBGMENU no \(t)"); break }
                if i == path.count - 1 {
                    if menu.items[idx].isEnabled { menu.performActionForItem(at: idx) } else { NSLog("DBGMENU disabled \(t)") }
                } else {
                    m = menu.items[idx].submenu
                }
            }
        case "ctxmenu":
            // Context menu for the current selection (or the background), with enabled state.
            guard let w = wc else { return }
            let m = w.contextMenu(for: w.view.model.selectedItems.first, in: w.view)
            m.update()
            let lines = m.items.map { it -> String in
                it.isSeparatorItem
                    ? "---"
                    : (it.view != nil
                        ? "[view \(type(of: it.view!))]"
                        : "\(it.title)\(self.isEnabled(it) ? "" : " (disabled)")\(it.isAlternate ? " (alt)" : "")\(it.submenu != nil ? " ▸" : "")")
            }
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "key": sendKey(arg)
        case "search":
            // search <n|c> <text>: names or contents, here
            if let v = wc?.view, arg.count > 2 {
                v.showSearch()
                v.searchBar(v.searchBar, search: String(arg.dropFirst(2)), everywhere: false, contents: arg.hasPrefix("c"))
            }
        case "lagprobe":
            // lagprobe <file> <seconds>: the longest the main thread didn't answer, in ms, every 5 ms meanwhile
            let parts = arg.split(separator: " ").map(String.init)
            guard parts.count == 2, let secs = Double(parts[1]) else { break }
            var last = CACurrentMediaTime(), worst = 0.0
            let end = last + secs
            let t = Timer(timeInterval: 0.005, repeats: true) { t in
                let now = CACurrentMediaTime()
                worst = max(worst, now - last)
                last = now
                if now > end {
                    t.invalidate()
                    try? String(format: "%.1f", worst * 1000).write(toFile: parts[0], atomically: true, encoding: .utf8)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        case "set":
            // set <key> <json value>
            let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if kv.count == 2, let v = try? JSONSerialization.jsonObject(with: Data(kv[1].utf8), options: .fragmentsAllowed) {
                Settings.store.set(v, forKey: kv[0])
                NotificationCenter.default.post(name: Settings.changed, object: kv[0])
            }
        case "windows":
            let list = NSApp.windows.filter(\.isVisible).map { "\($0.title)|\(type(of: $0.windowController as Any))|key=\($0.isKeyWindow)" }
            try? list.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "navigate": wc?.view.setURL(arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : (URL(string: arg) ?? URL(fileURLWithPath: arg)))
        case "action":
            if let w = wc, w.responds(to: NSSelectorFromString(arg)) {
                NSApp.sendAction(NSSelectorFromString(arg), to: w, from: nil)
            } else {
                NSApp.sendAction(NSSelectorFromString(arg), to: nil, from: nil)
            }
        case "select":
            if let v = wc?.view { v.list.select(arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : v.url.appendingPathComponent(arg)) }
        case "settings":
            AppDelegate.shared.showSettings(nil)
            if let i = Int(arg), let tabs = settingsWindow?.contentViewController as? NSTabViewController {
                tabs.selectedTabViewItemIndex = i
            }
        case "hit":
            // hit <x> <y> <outfile>: which view is under a point (window coords from the top-left)
            let a = arg.split(separator: " ").map(String.init)
            if let w = wc?.window, let fv = w.contentView?.superview, a.count == 3, let x = Double(a[0]), let y = Double(a[1]) {
                let p = CGPoint(x: x, y: w.frame.height - y)
                var chain: [String] = []
                var v = fv.hitTest(p)
                while let cur = v { chain.append(String(describing: type(of: cur))); v = cur.superview }
                try? chain.joined(separator: " < ").write(toFile: a[2], atomically: true, encoding: .utf8)
            }
        default: break
        }
    }

    /// PNG of the key window including the title bar area (traffic lights are drawn by the frame view).
    private func snapshot(to path: String) {
        guard let w = NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is MainWindowController }) ?? NSApp.keyWindow,
            let frameView = w.contentView?.superview
        else { return }
        let b = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: b) else { return }
        frameView.cacheDisplay(in: b, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Real composited capture of our own window (materials, glass) via the window server.
    /// CGWindowListCreateImage is hidden from Swift in newer SDKs; capturing one's own windows needs no permission.
    private func windowServerSnapshot(to arg: String) {
        // "wsnapshot <png>" = main window; "wsnapshot <png>|<title prefix>" = another window (Settings, Properties…).
        let parts = arg.components(separatedBy: "|")
        let path = parts[0]
        // The Settings window is titled after its page: "Settings" finds it whatever page is shown.
        let w: NSWindow? =
            parts.count > 1
            ? (parts[1] == "Settings" ? settingsWindow : NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(parts[1]) })
            : NSApp.orderedWindows.first(where: { $0.windowController is MainWindowController })
        guard let w else { return }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
        guard let img = fn(.null, 8, UInt32(w.windowNumber), 1)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Snapshot through Core Animation (captures layer-drawn content like the terminal).
    private func layerSnapshot(to path: String) {
        guard let w = NSApp.orderedWindows.first(where: { $0.windowController is MainWindowController }),
            let v = w.contentView?.superview, let layer = v.layer
        else { return }
        let scale = w.backingScaleFactor
        let size = CGSize(width: v.bounds.width * scale, height: v.bounds.height * scale)
        guard
            let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func writeState(to path: String) {
        guard let w = wc else { return }
        let v = w.view
        let state: [String: Any] = [
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
            "activeIsSecondary": w.tab.activeIsSecondary,
            "filterVisible": !v.filterBar.isHidden,
            "searchVisible": !v.searchBar.isHidden,
            "status": v.statusBar.displayText,
            "panels": ["places": w.showPlaces, "folders": w.showFolders, "info": w.showInformation, "terminal": w.showTerminal],
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
            "quickLookVisible": QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible,
            "keyWindowTitle": NSApp.keyWindow?.title ?? "",
            "locationText": (w.window?.firstResponder as? NSTextView)?.string ?? "",
            "windowFrame": w.window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
            "screenHeight": NSScreen.screens.first?.frame.height ?? 0,
            "isKey": w.window?.isKeyWindow ?? false,
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
    private func remoteTest(_ arg: String) {
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
    private func isEnabled(_ it: NSMenuItem) -> Bool {
        if NSApp.keyWindow == nil, it.target == nil, let a = it.action, let w = wc, w.responds(to: a) { return w.validateMenuItem(it) }
        return it.isEnabled
    }

    /// Every item of a menu (and its submenus) with its shortcut and enabled state (after validation).
    private func dumpMenu(_ menu: NSMenu, to path: String) {
        var out: [String] = []
        func walk(_ m: NSMenu, _ prefix: String) {
            m.delegate?.menuNeedsUpdate?(m)  // as when the menu opens (dynamic submenus fill themselves)
            m.update()
            for it in m.items where !it.isSeparatorItem {
                var k = it.keyEquivalent
                if let c = k.unicodeScalars.first, c.value >= 0xF700 {
                    let names: [UInt32: String] = [0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0xF728: "⌦", 0xF729: "Home", 0xF72B: "End"]
                    k = names[c.value] ?? (c.value >= 0xF704 && c.value <= 0xF726 ? "F\(Int(c.value) - 0xF703)" : "?")
                }
                if k == "\u{8}" || k == "\u{7f}" { k = "⌫" }
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
    private func dumpSettings(to path: String) {
        guard let tabs = settingsWindow?.contentViewController as? NSTabViewController else { return }
        var out: [String] = []
        func walk(_ v: NSView) {
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

    /// Delivers a key press inside this app only: "cmd+shift+n", "f10", "down", "cmd+,".
    private func sendKey(_ spec: String) {
        var parts = spec.split(separator: "+").map(String.init)
        let k = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        for p in parts {
            switch p {
            case "cmd": flags.insert(.command);
            case "shift": flags.insert(.shift);
            case "opt": flags.insert(.option);
            case "ctrl": flags.insert(.control);
            default: break
            }
        }
        let special: [String: (UInt16, Int)] = [
            "up": (126, NSUpArrowFunctionKey), "down": (125, NSDownArrowFunctionKey), "left": (123, NSLeftArrowFunctionKey),
            "right": (124, NSRightArrowFunctionKey), "return": (36, 13), "esc": (53, 27), "tab": (48, 9), "space": (49, 32), "backspace": (51, 127),
            "delete": (117, NSDeleteFunctionKey), "home": (115, NSHomeFunctionKey), "end": (119, NSEndFunctionKey),
        ]
        let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ";": 41, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47,
        ]
        var chars = k, code: UInt16 = k.count == 1 ? letters[Character(k)] ?? 0 : 0
        if let s = special[k] {
            code = s.0; chars = String(Character(UnicodeScalar(s.1)!))
        } else if k.hasPrefix("f"), let n = Int(k.dropFirst()) {
            let codes: [Int: UInt16] = [1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100, 9: 101, 10: 109, 11: 103, 12: 111]
            code = codes[n] ?? 0; chars = String(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!)); flags.insert(.function)
        }
        if ["up", "down", "left", "right", "delete", "home", "end"].contains(k) { flags.insert([.function, .numericPad]) }
        let ignoring = chars
        if flags.contains(.shift), chars.count == 1, chars.first?.isLetter == true { chars = chars.uppercased() }
        guard let w = wc?.window ?? NSApp.windows.first(where: \.isVisible),
            let e = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: w.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)
        else { return }
        let target = NSApp.keyWindow ?? w
        if !flags.intersection([.command, .control]).isEmpty || k.hasPrefix("f") {
            if target.performKeyEquivalent(with: e) { return }
            if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return }
        }
        target.sendEvent(e)
    }
}
