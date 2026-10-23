import AppKit
import PorpoiseCore
import PorpoiseServices

/// One immutable listing/selection snapshot per generation. No selection walks or UTType matching in menu validation.
@MainActor final class CustomToolAvailabilityCache {
    private struct Key: Equatable {
        let model: ObjectIdentifier
        let rows: UInt64
        let selection: UInt64
        let folder: URL
        let otherFolder: URL?
        let tools: [CustomTool]
    }
    private var key: Key?
    private var generation: UInt64 = 0
    private var ready = false
    private var reasons: [UUID: String] = [:]
    private var completions: [() -> Void] = []

    func preparedReason(for id: UUID) -> String? { ready ? reasons[id] : "Checking selection…" }

    func reason(for tool: CustomTool, in owner: MainWindowController, updated: (() -> Void)? = nil) -> String? {
        let model = owner.view.model
        let next = Key(
            model: ObjectIdentifier(model), rows: model.rowsRevision, selection: model.selectionRevision,
            folder: owner.view.url, otherFolder: owner.tab.inactive?.url, tools: Settings.shared.customTools)
        if key != next {
            key = next; generation &+= 1; ready = false; reasons = [:]; completions = []
            let token = generation, rows = model.rows, selection = model.selection
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let items = rows.compactMap { selection.contains($0.item.url) ? $0.item : nil }
                let context = CustomToolContext(folder: next.folder, otherFolder: next.otherFolder, items: items)
                var reasons: [UUID: String] = [:]
                for tool in next.tools { if let reason = tool.unavailableReason(in: context) { reasons[tool.id] = reason } }
                let result = reasons
                RunLoop.main.perform(inModes: [.common]) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == token else { return }
                        self.reasons = result; self.ready = true
                        let callbacks = self.completions; self.completions = []
                        for callback in callbacks { callback() }
                    }
                }
            }
        }
        if !ready { if let updated, completions.count < 1000 { completions.append(updated) }; return "Checking selection…" }
        return reasons[tool.id]
    }
}
