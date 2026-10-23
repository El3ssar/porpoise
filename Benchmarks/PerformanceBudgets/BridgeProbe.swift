// Fixed probe overlaid into both benchmark checkouts. It is not part of the shipping target.
#if PORPOISE_TEST_HOOKS
import AppKit
import Foundation
import QuartzCore

extension DebugBridge {
    static let budgetCommands: [String: Command] = ["budget": DebugBridge.budgetCommand]

    func budgetCommand(_ argument: String) {
        guard let data = argument.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let operation = request["operation"] as? String, let report = request["report"] as? String,
            let view = wc?.view, let window = wc?.window
        else { return }
        // Launch sends readiness requests until the bridge answers. A completed reply retires all duplicates.
        guard operation != "ready" || !FileManager.default.fileExists(atPath: report) else { return }
        let model = view.model
        let start = ProcessInfo.processInfo.systemUptime
        let expected = request["expected"] as? Int ?? 0
        switch operation {
        case "listing":
            guard let path = request["directory"] as? String else { return }
            view.setURL(URL(fileURLWithPath: path))
        case "search":
            view.showSearch()
            view.searchBar.contents = false
            view.searchBar.everywhere = false
            view.searchBar.field.stringValue = "needle-target"
            view.searchBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.searchBar.field))
        case "ready":
            window.setContentSize(NSSize(width: 1180, height: 760))
            modeCommand("details")
        default: return
        }
        @MainActor func poll() {
            guard operation != "ready" || !FileManager.default.fileExists(atPath: report) else { return }
            let ready: Bool
            switch operation {
            case "listing": ready = !model.isLoading && !model.isSearching && model.items.count == expected && model.rows.count == expected
            case "search": ready = model.isSearching && !model.isLoading && model.rows.count == expected
            default: ready = window.isVisible && !model.isLoading && model.rows.count == expected
            }
            if ready && window.isVisible && window.occlusionState.contains(.visible) {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                CATransaction.flush()
                let value: [String: Any] = [
                    "schema": 1, "operation": operation, "seconds": ProcessInfo.processInfo.systemUptime - start,
                    "rows": model.rows.count, "visible": window.isVisible, "active": NSApp.isActive,
                    "occluded": !window.occlusionState.contains(.visible), "width": window.frame.width,
                    "height": window.frame.height, "mode": model.props.mode.rawValue,
                ]
                if let bytes = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
                    try? bytes.write(to: URL(fileURLWithPath: report), options: .atomic)
                }
            } else if ProcessInfo.processInfo.systemUptime - start < 120 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { poll() }
            } else {
                try? Data("{\"error\":\"probe timeout\"}".utf8).write(to: URL(fileURLWithPath: report), options: .atomic)
            }
        }
        poll()
    }
}
#endif
