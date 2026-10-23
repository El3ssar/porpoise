// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices

extension DebugBridge {
    static let columnCommands: [String: Command] = ["columns": DebugBridge.columnsCommand]

    /// Column view of the active pane, with mouse events through the window (its own hit-testing):
    /// `columns state <file>`: the first column, the focused one, each column's folder, width, icon size and scroll (JSON);
    /// `columns drag <column> <dx> [opt]`: drags the handle on that column's right edge by `dx` (with Option: every column);
    /// `columns click <column> <name> [2]`: clicks (or double-clicks) that item's row in that column;
    /// `columns cmdwheel <column> <clicks>`: ⌘ and the wheel over that column (up: bigger).
    func columnsCommand(_ arg: String) {
        let a = arg.split(separator: " ", maxSplits: 2).map(String.init)
        guard let sub = a.first, let pane = wc?.view, let b = pane.columnBrowser, let win = pane.window else { return }
        let shown = b.shownColumns
        func column(_ s: String) -> Int? { Int(s).flatMap { shown.indices.contains($0) ? $0 : nil } }
        func mouse(_ type: NSEvent.EventType, at p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            if let e = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
            {
                win.sendEvent(e)
            }
        }
        switch sub {
        case "state" where a.count == 2:
            let columns: [[String: Any]] = shown.map { v, url in
                let list = (v as? NSScrollView)?.documentView as? ItemListView
                return [
                    "folder": url?.lastPathComponent ?? "(preview)", "width": v.frame.width, "icon": list?.iconSize ?? 0,
                    "scrollY": list?.visibleRect.minY ?? 0, "focused": v === pane.scroll,
                    "selection": list.map { l in l.model.selection.map(\.lastPathComponent).sorted() } ?? [],
                ]
            }
            let out: [String: Any] = [
                "root": b.root.lastPathComponent, "focused": pane.url.lastPathComponent, "columns": columns,
                "history": pane.history.index, "savedWidth": ViewStyleStore().browserColumnWidth,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: URL(fileURLWithPath: a[1]))
            }
        case "drag" where a.count == 3:
            let rest = a[2].split(separator: " ")
            guard let i = column(a[1]), i < b.handles.count, let dx = rest.first.flatMap({ Double($0) }) else { return }
            let flags: NSEvent.ModifierFlags = rest.contains("opt") ? [.option] : []
            let h = b.handles[i]
            let start = h.convert(CGPoint(x: h.bounds.midX, y: h.bounds.maxY - ColumnResizeHandle.gripHeight / 2 - 4), to: nil)
            mouse(.leftMouseDown, at: start, flags: flags)
            for k in 1...12 { mouse(.leftMouseDragged, at: CGPoint(x: start.x + CGFloat(dx) * CGFloat(k) / 12, y: start.y), flags: flags) }
            mouse(.leftMouseUp, at: CGPoint(x: start.x + CGFloat(dx), y: start.y), flags: flags)
        case "click" where a.count == 3:
            var name = a[2], clicks = 1
            if name.hasSuffix(" 2") {
                name.removeLast(2)
                clicks = 2
            }
            guard let i = column(a[1]), let list = (shown[i].view as? NSScrollView)?.documentView as? ItemListView,
                let row = list.model.rows.firstIndex(where: { $0.item.name == name })
            else { return }
            if list.frames.count != list.model.rows.count { list.computeLayout() }
            list.scrollToItem(row)
            let p = list.convert(CGPoint(x: list.frames[row].midX, y: list.frames[row].midY), to: nil)
            for c in 1...clicks {
                mouse(.leftMouseDown, at: p, clicks: c)
                mouse(.leftMouseUp, at: p, clicks: c)
            }
        case "cmdwheel" where a.count == 3:
            guard let i = column(a[1]), let n = Int32(a[2]) else { return }
            let v = shown[i].view, seen = v.visibleRect
            let p = v.convert(CGPoint(x: seen.midX, y: seen.midY), to: nil)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: n, wheel2: 0, wheel3: 0)
            // A window-less event's location reads as its point in the window: the window hit-tests it there.
            cg?.location = CGPoint(x: p.x, y: top - p.y)
            cg?.flags = .maskCommand
            if let e = cg.flatMap({ NSEvent(cgEvent: $0) }) { win.sendEvent(e) }
        default: return
        }
    }
}

#endif
