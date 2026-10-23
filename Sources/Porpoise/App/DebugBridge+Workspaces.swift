// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices

extension DebugBridge {
    /// Window layouts, named workspaces and Quick Select.
    static let workspaceCommands: [String: Command] = [
        "layout": DebugBridge.layoutCommand,
        "applylayout": DebugBridge.applylayoutCommand,
        "workspace": DebugBridge.workspaceCommand,
        "quickselect": DebugBridge.quickselectCommand,
        "panes": DebugBridge.panesCommand,
        "filterset": DebugBridge.filtersetCommand,
    ]

    /// panes <file>: every pane of the front window, tab by tab: its location, whether it has listed it yet, and
    /// what its empty list says (an offline server's error and its action).
    func panesCommand(_ arg: String) {
        guard let w = wc else { return }
        let panes = w.tabs.enumerated().flatMap { i, t in
            t.containers.map { c -> [String: Any] in
                [
                    "tab": i, "url": c.url.absoluteString, "waitsToLoad": c.waitsToLoad, "loading": c.model.isLoading,
                    "rows": c.model.rows.count, "state": c.listState.isHidden ? "" : c.listState.state?.title ?? "",
                    "action": c.listState.isHidden ? "" : c.listState.state?.action?.title ?? "",
                ]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: panes, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: arg))
        }
    }

    /// filterset <text>[|glob|regex][|locked]: shows the filter bar with that filter in the front view.
    func filtersetCommand(_ arg: String) {
        guard let v = wc?.view else { return }
        let p = arg.components(separatedBy: "|")
        let mode = p.contains("glob") ? FilterMode.glob : p.contains("regex") ? .regex : .plainText
        v.filterBar.isHidden = false
        v.filterBar.isLocked = p.contains("locked")
        v.filterBar.set(NameFilter(text: p[0], mode: mode))
        v.needsLayout = true
    }

    /// layout <file>: the front window's layout as JSON (what a workspace saves).
    func layoutCommand(_ arg: String) {
        guard let w = wc else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(w.captureLayout()).write(to: URL(fileURLWithPath: arg))
    }

    /// applylayout <file>: shows the layout in that JSON file in the front window.
    func applylayoutCommand(_ arg: String) {
        guard let w = wc, let data = try? Data(contentsOf: URL(fileURLWithPath: arg)),
            let layout = try? JSONDecoder().decode(WindowLayout.self, from: data)
        else { return }
        w.applyLayout(layout)
    }

    /// workspace save <name> | open <name> | opennew <name> | delete <name> | list <file> | sheet | sheetname <name> | sheetsave
    func workspaceCommand(_ arg: String) {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let rest = parts.count > 1 ? parts[1] : ""
        let found = Workspace.named(rest, in: Settings.shared.workspaces)
        switch verb {
        case "save": if let w = wc { Settings.shared.saveWorkspace(named: rest, layout: w.captureLayout()) }
        case "open": if let w = wc, let found { w.open(found) }
        case "opennew":
            if let found {
                AppDelegate.shared.newWindow(at: Settings.shared.homeURL)
                AppDelegate.shared.windows.last?.open(found)
            }
        case "delete": if let found { Settings.shared.deleteWorkspace(id: found.id) }
        case "list":
            let names = Settings.shared.workspaces.map { ["name": $0.name, "tabs": $0.layout.tabs.count] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: names, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: rest))
            }
        case "sheet": wc?.saveWorkspace(nil)
        case "sheetname":
            if let s = WorkspaceSaveSheet.active {
                s.field.stringValue = rest
                s.validate()
            }
        case "sheetsave": WorkspaceSaveSheet.active?.pressSave()
        default: break
        }
    }

    /// quickselect <criterion>|<action>|<text>[|case]: applies Quick Select to the front view.
    /// quickselect sheet <criterion>|<action>|<text>: opens the sheet filled in (for captures); quickselect press: its
    /// default button; quickselect cancel.
    func quickselectCommand(_ arg: String) {
        if arg == "press" { QuickSelectSheet.active?.pressSelect(); return }
        if arg == "cancel" { QuickSelectSheet.active?.finish(false); return }
        let sheet = arg.hasPrefix("sheet ")
        let p = (sheet ? String(arg.dropFirst(6)) : arg).components(separatedBy: "|")
        guard let w = wc, p.count >= 3, let criterion = QuickSelect.Criterion(rawValue: p[0]), let action = QuickSelect.Action(rawValue: p[1])
        else { return }
        let q = QuickSelect(criterion, p[2], caseSensitive: p.count > 3 && p[3] == "case")
        if sheet {
            QuickSelectSheet.run(for: w, action: action)
            QuickSelectSheet.active?.fill(q, action: action)
        } else {
            w.applyQuickSelect(q, action: action)
        }
    }
}

#endif
