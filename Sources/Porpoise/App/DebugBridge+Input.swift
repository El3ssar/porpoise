import PorpoiseFileSystem

// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices

extension DebugBridge {
    /// Clicks, keys, menus, gestures and navigation, as a user would do them.
    static let inputCommands: [String: Command] = [
        "link": DebugBridge.linkCommand,
        "filediff": DebugBridge.filediffCommand,
        "filediffmode": DebugBridge.filediffmodeCommand,
        "panel": DebugBridge.panelCommand,
        "mode": DebugBridge.modeCommand,
        "activate": DebugBridge.activateCommand,
        "click": DebugBridge.clickCommand,
        "tag": DebugBridge.tagCommand,
        "hover": DebugBridge.hoverCommand,
        "scrollto": DebugBridge.scrolltoCommand,
        "pinch": DebugBridge.pinchCommand,
        "dragpb": DebugBridge.dragpbCommand,
        "droponto": DebugBridge.dropontoCommand,
        "rename": DebugBridge.renameCommand,
        "menu": DebugBridge.menuCommand,
        "ctxmenu": DebugBridge.ctxmenuCommand,
        "key": DebugBridge.keyCommand,
        "search": DebugBridge.searchCommand,
        "searchbar": DebugBridge.searchbarCommand,
        "navigate": DebugBridge.navigateCommand,
        "action": DebugBridge.actionCommand,
        "select": DebugBridge.selectCommand,
        "hit": DebugBridge.hitCommand,
    ]

    func linkCommand(_ arg: String) {
        if let wc, (wc.tab.linkedRoots != nil) != (arg == "on") { wc.toggleLinkedBrowsing(nil) }
    }

    func filediffCommand(_ arg: String) {
        let pair = arg.components(separatedBy: "|")
        if pair.count == 2 { FileDiffWindow.present(left: URL(fileURLWithPath: pair[0]), right: URL(fileURLWithPath: pair[1])) }
    }

    func filediffmodeCommand(_ arg: String) {
        FileDiffWindow.current?.debug(arg)
    }

    func panelCommand(_ arg: String) {
        if let w = wc {
            let tag = ["places": 0, "info": 1, "folders": 2, "terminal": 3, "shelf": 4][arg] ?? 3
            let it = NSMenuItem(); it.tag = tag
            w.togglePanel(it)
        }
    }

    func modeCommand(_ arg: String) {
        if let w = wc, let m = ViewMode(rawValue: arg) { w.view.setMode(m); w.syncToActiveView() }
    }

    func activateCommand(_ arg: String) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderedWindows.first { $0.windowController is MainWindowController }?.makeKeyAndOrderFront(nil)
    }

    /// click <window title prefix or "Settings">|<button title, or popup#N for the Nth popup>[|<popup item>]:
    /// clicks a button/checkbox, or picks a popup item, in any window of the app (no real mouse).
    func clickCommand(_ arg: String) {
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
    }

    func tagCommand(_ arg: String) {
        wc?.toggleTag(arg)
    }

    func hoverCommand(_ arg: String) {
        if let v = wc?.view { v.list.hoverIndex = v.model.rows.firstIndex { $0.item.name == arg } }
    }

    func scrolltoCommand(_ arg: String) {
        if let y = Double(arg) { wc?.view.list.scroll(CGPoint(x: 0, y: y)) }
    }

    /// pinch <factor>: a pinch at the middle of the visible area, released (committed) like a real gesture.
    func pinchCommand(_ arg: String) {
        guard let l = wc?.view.list, let f = Double(arg) else { return }
        let vr = l.visibleRect
        l.previewZoom(l.iconSize * CGFloat(f), anchor: CGPoint(x: vr.midX, y: vr.midY), commitAfter: 0)
    }

    /// Writes the selection the way a drag does, to a private pasteboard, and reports what other apps would read.
    func dragpbCommand(_ arg: String) {
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
    }

    /// droponto <folder>: drops the selection on a folder, as a drag with the move operation would.
    func dropontoCommand(_ arg: String) {
        guard let w = wc else { return }
        FileOperationsController.shared.handleDrop(
            w.view.model.selectedItems.map(\.url), onto: URL(fileURLWithPath: arg),
            operation: .move, in: w.view)
    }

    /// rename <path>|<new name>, through the normal rename path (async so the bridge returns).
    func renameCommand(_ arg: String) {
        let p = arg.components(separatedBy: "|")
        guard p.count == 2, let w = wc, let it = FileItem.load(URL(fileURLWithPath: p[0])) else { return }
        DispatchQueue.main.async { w.rename(it, to: p[1], in: w.view) }
    }

    /// menu Go/Desktop: performs a main-menu item by its titles (after validation).
    func menuCommand(_ arg: String) {
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
    }

    /// Context menu for the current selection (or the background), with enabled state.
    func ctxmenuCommand(_ arg: String) {
        guard let w = wc else { return }
        let m = w.contextMenu(for: w.view.model.selectedItems.first, in: w.view)
        m.update()
        let lines = m.items.map { it -> String in
            it.isSeparatorItem
                ? "---"
                : (it.view != nil
                    ? "[view \(type(of: it.view!))]"
                    : "\(it.title)\(self.isEnabled(it) ? "" : " (disabled)")\(it.isAlternate ? " (alt)" : "")\(it.submenu != nil ? " ▸" : "")"
                        + (it.toolTip.map { " — \($0)" } ?? ""))
        }
        var all = lines
        if let f = MainActor.assumeIsolated({ wc?.tab.lastFlight }) {
            let sizes = f.sizes.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
            all.append(
                "flight frames=\(f.sizes.count) sizes=\(sizes.joined(separator: ",")) landing=\(f.landing.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-") "
                    + "smooth=\(f.isSmooth) shownWhenCopiesWent=\(f.shownWhenCopiesWent)")
        }
        try? all.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
    }

    func keyCommand(_ arg: String) {
        sendKey(arg)
    }

    /// search <n|c|N|C> <text>: names or contents, here (lowercase) or everywhere (uppercase)
    func searchCommand(_ arg: String) {
        if let v = wc?.view, arg.count > 2 {
            v.showSearch()
            v.searchBar.field.stringValue = String(arg.dropFirst(2))
            v.searchBar.contents = arg.lowercased().hasPrefix("c")
            v.searchBar.everywhere = arg.first?.isUppercase == true
            v.searchBar.fire()
        }
    }

    /// searchbar <file>: the search bar's controls, left to right: title, frame, toggled
    func searchbarCommand(_ arg: String) {
        guard let bar = wc?.view.searchBar else { return }
        let lines = bar.subviews.sorted { $0.frame.minX < $1.frame.minX }.map { v in
            let b = v as? FlatButton
            return "\(b?.title ?? String(describing: type(of: v))) \(NSStringFromRect(v.frame)) \(b?.isToggled == true ? "on" : "")"
        }
        var all = lines
        if let f = MainActor.assumeIsolated({ wc?.tab.lastFlight }) {
            let sizes = f.sizes.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
            all.append(
                "flight frames=\(f.sizes.count) sizes=\(sizes.joined(separator: ",")) landing=\(f.landing.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-") "
                    + "smooth=\(f.isSmooth) shownWhenCopiesWent=\(f.shownWhenCopiesWent)")
        }
        try? all.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
    }

    func navigateCommand(_ arg: String) {
        wc?.view.setURL(arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : (URL(string: arg) ?? URL(fileURLWithPath: arg)))
    }

    func actionCommand(_ arg: String) {
        if let w = wc, w.responds(to: NSSelectorFromString(arg)) {
            NSApp.sendAction(NSSelectorFromString(arg), to: w, from: nil)
        } else {
            NSApp.sendAction(NSSelectorFromString(arg), to: nil, from: nil)
        }
    }

    func selectCommand(_ arg: String) {
        if let v = wc?.view { v.list.select(arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : v.url.appendingPathComponent(arg)) }
    }

    /// hit <x> <y> <outfile>: which view is under a point (window coords from the top-left)
    func hitCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        if let w = wc?.window, let fv = w.contentView?.superview, a.count == 3, let x = Double(a[0]), let y = Double(a[1]) {
            let p = CGPoint(x: x, y: w.frame.height - y)
            var chain: [String] = []
            var v = fv.hitTest(p)
            while let cur = v { chain.append(String(describing: type(of: cur))); v = cur.superview }
            try? chain.joined(separator: " < ").write(toFile: a[2], atomically: true, encoding: .utf8)
        }
    }

    /// Delivers a key press inside this app only: "cmd+shift+n", "f10", "down", "cmd+,".
    func sendKey(_ spec: String) {
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

#endif
