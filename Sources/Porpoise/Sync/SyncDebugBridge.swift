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
        if pieces[0] != "edit" { pair.mode = mode }
        let sheet = SyncSheetController(pair: pair, owner: window, editing: pieces[0] == "edit")
        if pieces[0] == "planning" { sheet.reviewPlanningDelay = 3 }
        sheet.present()
    }
    static func sidebar(_ argument: String) {
        if argument == "states" {
            SyncCoordinator.shared.installReviewSidebarStates(
                left: root.appendingPathComponent("Home/Projects"), right: root.appendingPathComponent("Backup/Projects"));
            return
        }
        // Only saved definitions are synthesized; actual watcher statuses come from real filesystem state.
        let left = root.appendingPathComponent("Home/Projects"), right = root.appendingPathComponent("Backup/Projects")
        var pair = SyncCoordinator.shared.pair(left: left, right: right) ?? SavedSync(left: left, right: right)
        pair.name = argument.isEmpty ? "Projects" : argument; pair.visibleInSidebar = true
        pair.lastSynced = Date().addingTimeInterval(-120)
        SyncCoordinator.shared.save(pair)
    }
    static func control(command: String, argument: String) {
        guard
            let sheet = NSApp.windows.first(where: { $0.isVisible && $0.windowController is SyncSheetController })?.windowController
                as? SyncSheetController
        else { return }
        let parts = argument.components(separatedBy: "|")
        if command == "syncinclude", parts.count == 2 { sheet.reviewInclude(parts[0], enabled: parts[1] != "off") }
        if command == "syncresolve", parts.count == 2, let choice = SyncOverride(rawValue: parts[1]) { sheet.reviewResolve(parts[0], choice: choice) }
        if command == "syncsize" {
            let sizes = argument.split(separator: " ").compactMap { Double($0) }
            if sizes.count == 2 { sheet.window?.setContentSize(CGSize(width: sizes[0], height: sizes[1])) }
        }
    }
    static func notifications(_ path: String) {
        let pair = SavedSync(
            id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!, name: "Website", left: URL(fileURLWithPath: "/Home/Photos"),
            right: URL(string: "sftp://nas.local/NAS")!)
        let payloads = [
            SyncNotificationPayload(pair: pair, event: .conflicts(2)),
            SyncNotificationPayload(pair: pair, event: .failure(reason: "server.local is full.", waiting: 18)),
            SyncNotificationPayload(pair: pair, event: .deletionReview(count: 340, destination: "Backup")),
        ]
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(payloads).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
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
