import AppKit
import PorpoiseCore
import PorpoiseServices

/// Deterministic UI fixtures are restricted to explicit test launches.
enum SyncDebugBridge {
    static var root: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["PORPOISE_SYNC_FIXTURE"] ?? NSTemporaryDirectory() + "porpoise-sync-fixture")
    }
    static func present(_ argument: String, window: NSWindow) {
        let pieces = argument.components(separatedBy: "|")
        let mode: SyncMode = pieces[0] == "mirror" ? .mirror : pieces[0] == "twoway" ? .twoWay : .backup
        let left = pieces.count > 1 ? URL(fileURLWithPath: pieces[1]) : root.appendingPathComponent("Home/Projects")
        let right = pieces.count > 2 ? URL(fileURLWithPath: pieces[2]) : root.appendingPathComponent("Backup/Projects")
        var newPair = SavedSync(left: left, right: right); newPair.visibleInSidebar = false
        var pair = SyncCoordinator.shared.pair(left: left, right: right) ?? newPair
        pair.mode = mode
        SyncSheetController(pair: pair, owner: window, editing: pieces[0] == "edit").present()
    }
    static func sidebar(_ argument: String) {
        // Only saved definitions are synthesized; actual watcher statuses come from real filesystem state.
        var pair = SavedSync(
            name: argument.isEmpty ? "Projects" : argument,
            left: root.appendingPathComponent("Home/Projects"), right: root.appendingPathComponent("Backup/Projects"))
        pair.lastSynced = Date().addingTimeInterval(-120)
        SyncCoordinator.shared.save(pair)
    }
    static func state(_ path: String) {
        let coordinator = SyncCoordinator.shared
        let rows: [[String: Any]] = coordinator.pairs.map { pair in
            [
                "id": pair.id.uuidString, "name": pair.name, "automatic": pair.automatic, "paused": pair.paused,
                "left": pair.left.path, "right": pair.right.path, "activity": coordinator.activities[pair.id]?.state.rawValue ?? "none",
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            DispatchQueue.global(qos: .utility).async { try? data.write(to: URL(fileURLWithPath: path)) }
        }
    }
}
