import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz
import SwiftTerm

/// Test hook: lets scripts ask the running app for a window snapshot or its state, and trigger actions,
/// via distributed notifications. Used by scripts/uitest.sh. Inert unless someone posts to it.
final class DebugBridge: NSObject {
    static let shared = DebugBridge()
    var compareEntryPhases: [String: Double] = [:]
    private var transferPreviewJob: FileJob?
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
        case "compare":
            let pair = arg.contains("|") ? arg.components(separatedBy: "|") : arg.split(separator: " ", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                wc?.startComparing(left: URL(fileURLWithPath: pair[0]), right: URL(fileURLWithPath: pair[1]))
            } else {
                wc?.toggleCompare(nil)
            }
        case "comparefilter":
            if let model = wc?.tab.compareView?.model {
                var filter: CompareFilter = []
                if arg == "all" {
                    filter = .all
                } else if arg == "differences" {
                    filter = .differences
                } else {
                    for token in arg.components(separatedBy: ",") {
                        filter.formUnion(["left": .onlyLeft, "right": .onlyRight, "changed": .changed, "same": .same][token] ?? [])
                    }
                }
                model.filter = filter; model.rebuild()
            }
        case "compareexpand": wc?.tab.compareView?.model.expand(arg)
        case "compareselect":
            if let compare = wc?.tab.compareView, let index = compare.model.rows.firstIndex(where: { $0.path == arg }) {
                compare.document.select(index)
            }
        case "comparemethod":
            if let method = SyncCompareMethod(rawValue: arg), let compare = wc?.tab.compareView {
                compare.model.options.method = method; compare.model.start()
            }
        case "compareprogress":
            if let model = wc?.tab.compareView?.model {
                if arg == "on", var partial = model.comparison {
                    model.stop(); partial.complete = false; partial.rows.removeAll { $0.path.contains("/") }
                    model.comparison = partial; model.outline = CompareOutline(partial); model.expanded = []
                    model.loading = true; model.showProgress = true; model.rebuild()
                } else {
                    model.start()
                }
            }
        case "comparehover":
            if let compare = wc?.tab.compareView, let index = Int(arg) { compare.document.hoverIndex = index; compare.document.needsDisplay = true }
        case "comparescroll":
            if let compare = wc?.tab.compareView, let offset = Double(arg) {
                compare.scroll.contentView.scroll(to: CGPoint(x: 0, y: offset)); compare.scroll.reflectScrolledClipView(compare.scroll.contentView)
            }
        case "comparemenu":
            if !arg.isEmpty { wc?.tab.compareView?.showMethodMenu { self.windowServerMenuSnapshot(to: arg) } }
        case "comparesplitmenu":
            guard Settings.isTesting, let toolbar = wc?.toolbar, let menu = toolbar.split.menuProvider?() else { break }
            let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
                self.windowServerMenuSnapshot(to: arg); menu.cancelTracking()
            }
            RunLoop.main.add(timer, forMode: .common)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: toolbar.split.bounds.height), in: toolbar.split)
        case "comparetheme":
            guard Settings.isTesting else { break }
            Settings.shared.updateAppearance { $0.themeName = arg }
        case "compareopaque":
            guard Settings.isTesting, let compare = wc?.tab.compareView else { break }
            compare.bar.forcesOpaque = arg == "on"; compare.footer.forcesOpaque = arg == "on"
        case "comparescrollbench":
            if let compare = wc?.tab.compareView {
                let probe = Animator(); var intervals: [Double] = [], previous = CACurrentMediaTime()
                compare.document.drawMilliseconds = []
                let start = compare.scroll.contentView.bounds.minY
                probe.run(
                    duration: 1, curve: { $0 },
                    step: { value in
                        let now = CACurrentMediaTime(); intervals.append((now - previous) * 1000); previous = now
                        compare.scroll.contentView.scroll(to: CGPoint(x: 0, y: start + CGFloat(value) * 2800))
                        compare.scroll.reflectScrolledClipView(compare.scroll.contentView)
                    })
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    _ = probe
                    let data: [String: Any] = [
                        "rows": compare.model.rows.count, "frameIntervalsMS": Array(intervals.dropFirst()),
                        "drawMS": compare.document.drawMilliseconds,
                    ]
                    try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg))
                }
            }
        case "compareentrybench":
            let args = arg.components(separatedBy: "|")
            if args.count == 3, let wc {
                let probe = Animator(); var intervals: [Double] = [], previous: CFTimeInterval?
                var setup = 0.0, ticks = 0
                probe.run(
                    duration: 1.8,
                    step: { _ in
                        let now = CACurrentMediaTime()
                        if let previous { intervals.append((now - previous) * 1000) }
                        previous = now; ticks += 1
                        // Warm the display link before measuring entry: registration-to-first-callback
                        // includes startup latency, rather than an interval between displayed frames.
                        if ticks == 2 {
                            let begin = CACurrentMediaTime()
                            wc.startComparing(left: URL(fileURLWithPath: args[1]), right: URL(fileURLWithPath: args[2]))
                            setup = (CACurrentMediaTime() - begin) * 1000
                        }
                    })
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
                    _ = probe
                    let compare = wc.tab.compareView
                    let data: [String: Any] = [
                        "entrySetupMS": setup, "rows": compare?.model.rows.count ?? 0,
                        "phasesMS": self.compareEntryPhases,
                        "frameIntervalsMS": intervals, "drawMS": compare?.document.drawMilliseconds ?? [],
                    ]
                    try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[0]))
                }
            }
        case "comparebench":
            if let compare = wc?.tab.compareView {
                let probe = Animator(); var intervals: [Double] = [], previous = CACurrentMediaTime()
                probe.run(
                    duration: 0.6,
                    step: { _ in
                        let now = CACurrentMediaTime(); intervals.append((now - previous) * 1000); previous = now
                    })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    compare.model.filter = .all; compare.model.rebuild()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    _ = probe
                    let data: [String: Any] = [
                        "rows": compare.model.rows.count, "filterTotalMS": compare.model.lastRebuildMilliseconds,
                        "viewUpdateMS": compare.lastUpdateMilliseconds, "rowLayoutMS": compare.document.filterMilliseconds,
                        "drawMS": compare.document.drawMilliseconds, "frameIntervalsMS": Array(intervals.dropFirst()),
                    ]
                    try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg))
                }
            }
        case "compareperf":
            if let compare = wc?.tab.compareView {
                let data: [String: Any] = [
                    "rows": compare.model.rows.count, "filterUpdateMS": compare.lastUpdateMilliseconds,
                    "rowLayoutMS": compare.document.filterMilliseconds, "drawMS": compare.document.drawMilliseconds,
                    "activityNotifications": compare.activityNotificationCount, "activityPaints": compare.activityPaintCount,
                ]
                try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg))
            }
        case "compareresizebench":
            guard let compare = wc?.tab.compareView else { break }
            let original = compare.frame
            var total: [Double] = [], layout: [Double] = [], drawing: [Double] = []
            for index in 0..<60 {
                let phase = Double(index) / 59 * 2, fraction = phase <= 1 ? phase : 2 - phase
                let started = CACurrentMediaTime()
                compare.frame.size.width = 600 + CGFloat(fraction) * max(0, original.width - 600)
                compare.layoutSubtreeIfNeeded()
                let laidOut = CACurrentMediaTime()
                compare.displayIfNeeded(); CATransaction.flush()
                let finished = CACurrentMediaTime()
                layout.append((laidOut - started) * 1000); drawing.append((finished - laidOut) * 1000); total.append((finished - started) * 1000)
            }
            compare.frame = original; compare.layoutSubtreeIfNeeded(); compare.displayIfNeeded()
            let data: [String: Any] = ["rows": compare.model.rows.count, "totalMS": total, "layoutMS": layout, "drawingMS": drawing]
            try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg))
        case "link":
            if let wc, (wc.tab.linkedRoots != nil) != (arg == "on") { wc.toggleLinkedBrowsing(nil) }
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
        case "zoomframes":
            // zoomframes <folder> <size> <count> <ms>: an animated zoom (Cmd+=) to <size>, the main window captured every
            // <ms> milliseconds from its start, as 00.png, 01.png… (00 is before it).
            let a = arg.split(separator: " ").map(String.init)
            guard a.count == 4, let size = Double(a[1]), let n = Int(a[2]), let ms = Int(a[3]), let list = wc?.view.zoomView else { return }
            try? FileManager.default.createDirectory(atPath: a[0], withIntermediateDirectories: true)
            // Kept in memory while the zoom runs (writing a PNG takes longer than a frame), written after the last.
            // Beside each frame, <k>.txt: when it was taken, the icon size and how far a glide has come.
            let t0 = CACurrentMediaTime()
            var shots: [(image: CGImage?, info: String)] = []
            func capture() {
                let info = String(
                    format: "t=%.0fms size=%.1f glide=%@", (CACurrentMediaTime() - t0) * 1000, list.iconSize,
                    list.glideProgress.map { String(format: "%.2f", $0) } ?? "-")
                shots.append((windowServerImage("", nominal: true), info))
                guard shots.count == max(2, n) else { return }
                for (k, s) in shots.enumerated() {
                    if let img = s.image { writePNG(img, to: a[0] + String(format: "/%02d.png", k)) }
                    try? s.info.write(toFile: a[0] + String(format: "/%02d.txt", k), atomically: true, encoding: .utf8)
                }
            }
            capture()
            list.animateZoom(to: CGFloat(size))
            for k in 1..<max(2, n) {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(k * ms)) { capture() }
            }
        case "resizeframes":
            // resizeframes <folder> <width> <height> <count> <ms>: resizes the main window, then captures it every <ms>
            // (the resize animations), timed in the app.
            let a = arg.split(separator: " ").map(String.init)
            guard a.count == 5, let w = Double(a[1]), let h = Double(a[2]), let n = Int(a[3]), let ms = Int(a[4]), let win = wc?.window
            else { return }
            try? FileManager.default.createDirectory(atPath: a[0], withIntermediateDirectories: true)
            var f = win.frame
            f.size = CGSize(width: w, height: h)
            win.setFrame(f, display: true)
            for k in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(k * ms)) { [weak self] in
                    self?.windowServerSnapshot(to: a[0] + String(format: "/%02d.png", k))
                    let info = self?.wc?.view.apps?.grid.animationInfo ?? "-"
                    try? info.write(toFile: a[0] + String(format: "/%02d.txt", k), atomically: true, encoding: .utf8)
                }
            }
        case "perfbench": perfBench(arg)
        case "animprobe":
            // animprobe <file>: runs a 0.3 s animation and writes how many frames it got (the display's ticks).
            var ticks = 0
            let probe = Animator()
            probe.run(duration: 0.3, step: { _ in ticks += 1 })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let screens = NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))" }.joined(separator: ", ")
                try? "ticks=\(ticks) running=\(probe.isRunning) main=\(NSScreen.main?.localizedName ?? "-") screens=\(screens)".write(
                    toFile: arg, atomically: true, encoding: .utf8)
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
                let tag = ["places": 0, "info": 1, "folders": 2, "terminal": 3, "shelf": 4][arg] ?? 3
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
        case "commandcatalog":
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
        case "shortcutsimport":
            let paths = arg.components(separatedBy: "|")
            guard paths.count == 2 else { return }
            let report: String
            do {
                MenuCommandRegistry.shared.refresh();
                try Settings.shared.importKeyboardShortcuts(
                    Data(contentsOf: URL(fileURLWithPath: paths[0])), actions: MenuCommandRegistry.shared.commands.map(\.definition));
                report = "ok"
            } catch { report = error.localizedDescription }
            try? report.write(toFile: paths[1], atomically: true, encoding: .utf8)
        case "toolbarlayout":
            let commands = arg.split(separator: ",").compactMap { ToolbarCommand(rawValue: String($0)) }
            if let editor = NSApp.windows.first(where: { $0.windowController is ToolbarCustomizationWindow })?.toolbar {
                editor.itemIdentifiers = commands.map(\.toolbarIdentifier)
            } else {
                Settings.shared.toolbarCommands = commands
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
            // search <n|c|N|C> <text>: names or contents, here (lowercase) or everywhere (uppercase)
            if let v = wc?.view, arg.count > 2 {
                v.showSearch()
                v.searchBar.field.stringValue = String(arg.dropFirst(2))
                v.searchBar.contents = arg.lowercased().hasPrefix("c")
                v.searchBar.everywhere = arg.first?.isUppercase == true
                v.searchBar.fire()
            }
        case "searchbar":
            // searchbar <file>: the search bar's controls, left to right: title, frame, toggled
            guard let bar = wc?.view.searchBar else { break }
            let lines = bar.subviews.sorted { $0.frame.minX < $1.frame.minX }.map { v in
                let b = v as? FlatButton
                return "\(b?.title ?? String(describing: type(of: v))) \(NSStringFromRect(v.frame)) \(b?.isToggled == true ? "on" : "")"
            }
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
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
        case "syncsheet":
            guard Settings.isTesting, let window = wc?.window else { return }
            SyncDebugBridge.present(arg, window: window)
        case "syncsidebar":
            guard Settings.isTesting else { return }
            SyncDebugBridge.sidebar(arg)
        case "syncinclude", "syncresolve", "syncsize":
            guard Settings.isTesting else { return }
            SyncDebugBridge.control(command: parts.first ?? "", argument: arg)
        case "syncremote":
            guard Settings.isTesting, let window = wc?.window else { return }
            SyncDebugBridge.remote(arg, window: window)
        case "syncnotifications":
            guard Settings.isTesting else { return }
            SyncDebugBridge.notifications(arg)
        case "syncmenu":
            guard Settings.isTesting, !arg.isEmpty else { return }
            wc?.places.reviewSyncContextMenu { self.windowServerMenuSnapshot(to: arg) }
        case "syncstate":
            guard Settings.isTesting else { return }
            SyncDebugBridge.state(arg)
        case "reviewfront":
            guard Settings.isTesting,
                let window = arg.isEmpty ? wc?.window : NSApp.windows.first(where: { $0.title.hasPrefix(arg) })
            else { return }
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.level = .floating
            window.orderFrontRegardless()
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case "comparejob": wc?.tab.compareView?.previewJob(arg)
        case "reviewcapture":
            // Keep activation, capture and its key-state evidence in one app-side transaction.
            guard Settings.isTesting, let window = wc?.window else { break }
            let args = arg.components(separatedBy: "|")
            if args.count > 1, ["light", "dark"].contains(args[1]) {
                Settings.store.set(args[1], forKey: "appearance")
                NotificationCenter.default.post(name: Settings.changed, object: "appearance")
            }
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.level = .floating
            window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.writeState(to: args[0] + ".state.json")
                self.windowServerSnapshot(to: args[0])
                if args.count > 2, args[2] == "crops", let image = self.windowServerImage(args[0]) {
                    let scale = CGFloat(image.width) / window.frame.width
                    let seam = CGRect(x: CGFloat(image.width) / 2 - 110 * scale, y: 0, width: 220 * scale, height: 130 * scale)
                    let footer = CGRect(x: 0, y: CGFloat(image.height) - 28 * scale, width: CGFloat(image.width), height: 28 * scale)
                    if let crop = image.cropping(to: seam) { self.writePNG(crop, to: args[0] + ".seam.png") }
                    if let crop = image.cropping(to: footer) { self.writePNG(crop, to: args[0] + ".footer.png") }
                    if let bar = self.wc?.tab.compareView?.bar {
                        let rect = bar.convert(bar.bounds, to: nil)
                        let pixels = CGRect(
                            x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                            width: rect.width * scale, height: rect.height * scale)
                        if let crop = image.cropping(to: pixels) { self.writePNG(crop, to: args[0] + ".bar.png") }
                    }
                }
            }
        case "transferdialog":
            guard Settings.isTesting, let owner = wc?.window else { return }
            let folder = arg == "folder"
            let source = FileItem(
                url: URL(fileURLWithPath: "/tmp/Incoming/Report.pdf"), name: folder ? "Project" : "Report.pdf", isDirectory: folder,
                size: arg == "identical" ? 3_100_000 : 4_300_000,
                modificationDate: Date(timeIntervalSince1970: arg == "older" ? 1_700_000_000 : 1_700_100_000), contentType: "com.adobe.pdf")
            let target = FileItem(
                url: URL(fileURLWithPath: "/tmp/Backup/Report.pdf"), name: folder ? "Project" : "Report.pdf", isDirectory: folder,
                size: 3_100_000, modificationDate: Date(timeIntervalSince1970: arg == "identical" ? 1_700_100_000 : 1_700_050_000),
                contentType: "com.adobe.pdf")
            let job = FileJob(kind: .copy, sources: [source.url], destinationFolder: target.url.deletingLastPathComponent())
            transferPreviewJob = job
            let began = CACurrentMediaTime()
            FileOperationsController.shared.ui?.resolveConflict(
                ConflictInfo(
                    source: source, destination: target, suggestedName: "Report 2.pdf", remainingConflicts: 42, differentItems: 30,
                    identicalItems: 12,
                    sourceFolder: folder ? TransferFolderSummary(itemCount: 13, bytes: 4_300_000) : nil,
                    destinationFolder: folder ? TransferFolderSummary(itemCount: 14, bytes: 3_100_000) : nil
                ), kind: .copy, window: owner,
                job: job
            ) { _ in }
            try? String(format: "%.3f ms", (CACurrentMediaTime() - began) * 1000).write(
                toFile: NSTemporaryDirectory() + "porpoise-conflict-present.txt", atomically: true, encoding: .utf8)
        case "transferdialogcancel":
            if let job = transferPreviewJob { FileOperationsController.shared.ui?.cancelConflict(for: job) }
            transferPreviewJob = nil
        case "transferstate":
            guard Settings.isTesting else { return }
            let rows = FileOperationsController.shared.activities.map { activity -> [String: Any] in
                [
                    "state": activity.state.rawValue, "phase": activity.progress?.phase.rawValue ?? "", "fraction": activity.fraction,
                    "title": activity.title, "status": activity.statusText, "hasWindow": activity.originWindow != nil,
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }
        case "transfercopy":
            guard Settings.isTesting else { return }
            let paths = arg.components(separatedBy: "|")
            if paths.count == 2 {
                FileOperationsController.shared.run(.copy, [URL(fileURLWithPath: paths[0])], to: URL(fileURLWithPath: paths[1]), window: wc?.window)
            }
        case "transferpopover":
            guard Settings.isTesting else { return }
            wc?.toolbar.transfers.showTransfers()
        case "activitypreview": activityPreview(arg)
        case "activitycontrol":
            let controller = FileOperationsController.shared
            for activity in controller.activities where activity.state.isActive {
                switch arg {
                case "pause": controller.pause(activity)
                case "resume": controller.resume(activity)
                case "cancel": controller.cancel(activity)
                default: break
                }
            }
        case "activitysize":
            let size = arg.split(separator: " ").compactMap { Double($0) }
            if size.count == 2 { ActivityWindowController.shared.window?.setContentSize(NSSize(width: size[0], height: size[1])) }
        case "action":
            if let w = wc, w.responds(to: NSSelectorFromString(arg)) {
                NSApp.sendAction(NSSelectorFromString(arg), to: w, from: nil)
            } else {
                NSApp.sendAction(NSSelectorFromString(arg), to: nil, from: nil)
            }
        case "select":
            if let v = wc?.view { v.list.select(arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : v.url.appendingPathComponent(arg)) }
        case "appearanceexport":
            try? Settings.shared.exportAppearance().write(to: URL(fileURLWithPath: arg))
        case "appearanceimport":
            if let data = try? Data(contentsOf: URL(fileURLWithPath: arg)) { try? Settings.shared.importAppearance(data) }
        case "settingssize":
            let dimensions = arg.split(separator: " ").compactMap { Double($0) }
            if dimensions.count == 2 { settingsWindow?.setContentSize(NSSize(width: dimensions[0], height: dimensions[1])) }
        case "settingsscroll":
            if let y = Double(arg), let tabs = settingsWindow?.contentViewController as? NSTabViewController,
                let scroll = tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex]?.viewController?.view as? NSScrollView
            {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
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

    /// Isolated visual-review fixture: real copy plus explicit failed/running plan states. Test bridge only.
    private func activityPreview(_ path: String) {
        let root = URL(fileURLWithPath: path).appendingPathComponent("activity-" + UUID().uuidString)
        let source = root.appendingPathComponent("Project notes.txt")
        let destination = root.appendingPathComponent("Reports")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data(repeating: 65, count: 2_100_000).write(to: source)
            let controller = FileOperationsController.shared
            controller.clearEnded()
            controller.concurrency = 2
            controller.run(.copy, [source], to: destination, window: nil)
            let failed = PlanJournal(
                title: "Syncing Documents to Backup", steps: [PlanStep(id: "failed", title: "Copy archive.zip", payload: Data())])
            _ = try controller.enqueuePlan(failed) { _, _ in throw FileOperationError.failed("Backup is full") }
            let running = PlanJournal(
                title: "Syncing Projects to Backup", steps: [PlanStep(id: "copy", title: "Copying project files", payload: Data())])
            _ = try controller.enqueuePlan(running) { _, context in
                for index in 1200..<3000 {
                    try context.checkCancellation()
                    context.report(fraction: Double(index) / 3000)
                    Thread.sleep(forTimeInterval: 0.04)
                }
            }
            ActivityWindowController.shared.show()
        } catch {
            NSLog("Activity preview failed: %@", error.localizedDescription)
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
    /// Frame costs, timed in the app and written to <file>:
    /// `perfbench <file> resize <w0> <w1> <steps>`: the main window resized step by step, each step laid out and drawn.
    /// `perfbench <file> zoom <size0> <size1> <steps>`: the view (or the app library) zoomed step by step (as a pinch or the
    /// animation does).
    /// `perfbench <file> zoomanim <size>`: an animated zoom (Cmd+=), counting the frames it showed.
    private func perfBench(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        guard a.count >= 3, let win = wc?.window, let list = wc?.view.zoomView else { return }
        let n = a.dropFirst(2).compactMap { Double($0) }
        func report(_ times: [Double], extra: String = "") {
            let ms = times.map { $0 * 1000 }.sorted()
            let mean = ms.reduce(0, +) / Double(max(1, ms.count))
            let line = String(
                format: "%@ n=%d mean=%.2fms p50=%.2fms p90=%.2fms max=%.2fms%@", a[1], ms.count, mean,
                ms.isEmpty ? 0 : ms[ms.count / 2], ms.isEmpty ? 0 : ms[ms.count * 9 / 10], ms.last ?? 0, extra)
            try? line.write(toFile: a[0], atomically: true, encoding: .utf8)
        }
        // Layer-backed views draw when Core Animation commits: flushed here, so the time includes the drawing.
        func timed(_ body: () -> Void) -> Double {
            let t = CACurrentMediaTime()
            body()
            win.displayIfNeeded()
            CATransaction.flush()
            return CACurrentMediaTime() - t
        }
        switch a[1] {
        case "resize" where n.count == 3:
            var f = win.frame
            let steps = Int(n[2])
            report(
                (0..<steps).map { k in
                    // There and back, like a hand dragging the window's edge.
                    let t = Double(k) / Double(max(1, steps - 1)) * 2
                    f.size.width = n[0] + (n[1] - n[0]) * (t <= 1 ? t : 2 - t)
                    return timed { win.setFrame(f, display: true) }
                })
        case "zoom" where n.count == 3:
            let steps = Int(n[2])
            report(
                (0..<steps).map { k in
                    let s = n[0] + (n[1] - n[0]) * Double(k) / Double(max(1, steps - 1))
                    return timed { list.previewZoom(CGFloat(s), anchor: nil, commitAfter: nil) }
                })
            list.commitZoom()
        case "zoomanim" where n.count == 1:
            // Sizes the view showed while the animation ran, seen from a timer: one per frame drawn.
            var sizes: [CGFloat] = [list.iconSize], gaps: [Double] = []
            var last = CACurrentMediaTime()
            let end = last + 0.8
            list.animateZoom(to: CGFloat(n[0]))
            let t = Timer(timeInterval: 0.002, repeats: true) { t in
                let now = CACurrentMediaTime()
                gaps.append(now - last)
                last = now
                if list.iconSize != sizes.last { sizes.append(list.iconSize) }
                if now > end {
                    t.invalidate()
                    report(gaps.filter { $0 > 0.004 }, extra: " frames=\(sizes.count - 1) sizes=\(sizes.map { Int($0) })")
                }
            }
            RunLoop.main.add(t, forMode: .common)
        default: return
        }
    }

    private func windowServerSnapshot(to arg: String) {
        // "wsnapshot <png>" = main window; "wsnapshot <png>|<title prefix>" = another window (Settings, Properties…).
        guard let img = windowServerImage(arg) else { return }
        writePNG(img, to: arg.components(separatedBy: "|")[0])
    }

    private func writePNG(_ img: CGImage, to path: String) {
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Includes the native popup menu, which is a separate WindowServer window. Only this process's
    /// onscreen windows are captured, so another app's content cannot enter a design review artifact.
    private func windowServerMenuSnapshot(to path: String) {
        let native = NSApp.windows.filter(\.isVisible).sorted { $0.level.rawValue > $1.level.rawValue }
        let metadata = native.map {
            [
                "id": $0.windowNumber, "level": $0.level.rawValue, "type": String(describing: type(of: $0)),
                "title": $0.title, "frame": NSStringFromRect($0.frame),
            ] as [String: Any]
        }
        try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(
            to: URL(fileURLWithPath: path + ".native.json"))
        if let popup = native.first(where: { $0 !== wc?.window && $0.frame.height < 500 }) {
            typealias Single = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                let capture = unsafeBitCast(sym, to: Single.self)
                if let image = capture(.null, 8, UInt32(popup.windowNumber), 1)?.takeRetainedValue() {
                    writePNG(image, to: path); return
                }
            }
        }
        let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) }
        try? JSONSerialization.data(withJSONObject: owned, options: [.prettyPrinted, .sortedKeys]).write(
            to: URL(fileURLWithPath: path + ".windows.json"))
        // Direct window IDs work without broad screen-recording access; CGWindowList can be empty.
        // Native popup windows are present here even though main-window screenshots exclude them.
        var ids: [UnsafeRawPointer?] = NSApp.windows.filter(\.isVisible).sorted { $0.level.rawValue > $1.level.rawValue }
            .compactMap { UnsafeRawPointer(bitPattern: $0.windowNumber) }
        typealias Fn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let count = ids.count
        let windows = ids.withUnsafeMutableBufferPointer { buffer in CFArrayCreate(nil, buffer.baseAddress, count, nil) }
        if let windows, let image = fn(.null, windows, 1)?.takeRetainedValue() { writePNG(image, to: path) }
    }

    /// `nominal`: at 1x, much quicker to take (frames of an animation).
    private func windowServerImage(_ arg: String, nominal: Bool = false) -> CGImage? {
        let parts = arg.components(separatedBy: "|")
        // The Settings window is titled after its page: "Settings" finds it whatever page is shown.
        let w: NSWindow?
        if parts.count > 1 {
            switch parts[1] {
            case "Settings": w = settingsWindow
            case "Sheet": w = NSApp.windows.first { $0.isVisible && $0.isSheet }
            default: w = NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(parts[1]) }
            }
        } else {
            w = NSApp.orderedWindows.first { $0.windowController is MainWindowController }
        }
        guard let w else { return nil }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1, kCGWindowImageNominalResolution = 16
        return fn(.null, 8, UInt32(w.windowNumber), nominal ? 17 : 1)?.takeRetainedValue()
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
            "toolbarCommands": Settings.shared.toolbarCommands.map(\.rawValue),
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
            "compareChooser": w.tab.compareChooser != nil,
            "compare": w.tab.compareView.map { compare -> [String: Any] in
                [
                    "rows": compare.model.rows.count, "selected": compare.document.selectedPath ?? "",
                    "activeSide": compare.document.activeSide.rawValue,
                    "filter": compare.model.filter.rawValue, "sort": compare.model.sortRole.rawValue, "ascending": compare.model.sortAscending,
                    "complete": compare.model.comparison?.complete ?? false, "loading": compare.model.loading,
                    "scrollY": compare.scroll.contentView.bounds.minY, "iconSize": compare.zoom.doubleValue,
                    "left": compare.model.leftRoot.absoluteString, "right": compare.model.rightRoot.absoluteString,
                    "samplePaths": Array(compare.model.rowPaths.prefix(20)),
                    "accessibilityRows": compare.document.accessibilityChildren()?.count ?? 0,
                ]
            } ?? [:],
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
            "quickLookVisible": QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible,
            "keyWindowTitle": NSApp.keyWindow?.title ?? "",
            "locationText": (w.window?.firstResponder as? NSTextView)?.string ?? "",
            "windowFrame": w.window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
            "screenHeight": NSScreen.screens.first?.frame.height ?? 0,
            "isKey": w.window?.isKeyWindow ?? false,
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
        let target = NSApp.keyWindow?.attachedSheet ?? NSApp.keyWindow ?? w
        if !flags.intersection([.command, .control]).isEmpty || k.hasPrefix("f") {
            if target.performKeyEquivalent(with: e) { return }
            if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return }
        }
        target.sendEvent(e)
    }
}
