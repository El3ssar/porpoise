import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite struct SavedSyncTests {
    @Test func definitionsRoundTripAndCredentialsAreRejected() async throws {
        let scratch = try Scratch("saved-sync")
        let store = SavedSyncStore(file: scratch.path("settings/syncs.json"))
        var pair = SavedSync(name: "Projects", left: scratch.path("left"), right: scratch.path("right"), mode: .twoWay)
        pair.automatic = true; pair.presets.insert(.build); pair.customExclusions = ["*.tmp"]
        try await store.save([pair])
        #expect(try await store.load() == [pair])
        pair.right = URL(string: "sftp://person:secret@example.test/backup")!
        await #expect(throws: SyncEngineError.self) { try await store.save([pair]) }
        let text = try String(contentsOf: scratch.path("settings/syncs.json"), encoding: .utf8)
        #expect(!text.contains("secret"))
        #expect(try await store.load().first?.right == scratch.path("right"))
    }
    @Test func malformedOrFutureDefinitionsAreRetainedAndNeverReset() async throws {
        let scratch = try Scratch("saved-sync-version")
        let file = scratch.path("syncs.json")
        let data = Data(#"{"version":99,"pairs":[]}"#.utf8)
        try data.write(to: file)
        let store = SavedSyncStore(file: file)
        await #expect(throws: SyncEngineError.self) { try await store.load() }
        #expect(try Data(contentsOf: file) == data)
    }
    @Test func firstTwoWayCopiesBothSidesAndNeverDeletes() throws {
        let scratch = try Scratch("saved-sync-first")
        let left = scratch.path("left"), right = scratch.path("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: left.appendingPathComponent("left.txt"))
        try Data("right".utf8).write(to: right.appendingPathComponent("right.txt"))
        try Data("noise".utf8).write(to: left.appendingPathComponent(".DS_Store"))
        let pair = SavedSync(left: left, right: right, mode: .twoWay)
        let preview = try SyncPreparation.preview(pair)
        #expect(preview.firstTwoWay)
        #expect(preview.deletionCount == 0)
        #expect(preview.plan.steps.filter { $0.action == .copy }.count == 2)
        #expect(!preview.comparison.rows.contains { $0.path == ".DS_Store" })
        try SyncExecutor.execute(preview.executable, leftRoot: left, rightRoot: right)
        #expect(try Data(contentsOf: left.appendingPathComponent("right.txt")) == Data("right".utf8))
        #expect(try Data(contentsOf: right.appendingPathComponent("left.txt")) == Data("left".utf8))
    }
    @Test func conflictsAreOmittedWhileSafeItemsContinueAndSkippedParentsProtectChildren() throws {
        let scratch = try Scratch("saved-sync-conflicts")
        let left = scratch.path("left"), right = scratch.path("right")
        for root in [left, right] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: root.appendingPathComponent("both.txt"))
        }
        let before = try SyncScanner.compare(left, right)
        let state = SyncState(left: before.left, right: before.right)
        try Data("changed left".utf8).write(to: left.appendingPathComponent("both.txt"))
        try Data("changed right side".utf8).write(to: right.appendingPathComponent("both.txt"))
        try Data("new".utf8).write(to: left.appendingPathComponent("new.txt"))
        let pair = SavedSync(left: left, right: right, mode: .twoWay)
        let preview = try SyncPreparation.preview(pair, previous: state)
        #expect(preview.skippedConflicts == 1)
        #expect(preview.executable.conflicts.isEmpty)
        try SyncExecutor.execute(preview.executable, leftRoot: left, rightRoot: right)
        #expect(try String(contentsOf: right.appendingPathComponent("both.txt"), encoding: .utf8) == "changed right side")
        #expect(try String(contentsOf: right.appendingPathComponent("new.txt"), encoding: .utf8) == "new")
        let skipped = SyncPreparation.replan(preview, pair: pair, previous: state, overrides: ["new.txt": .skip])
        #expect(skipped.hasSkippedItems)
        #expect(!skipped.plan.steps.contains { $0.path == "new.txt" })
    }
    @Test func largeDeletionThresholdUsesEachDestinationAndBothStrictBounds() {
        let entries = (0..<100).map { SyncEntry(path: "\($0)") }
        let left = SyncSnapshot(entries: entries), right = SyncSnapshot(entries: [])
        let comparison = SyncComparator.compare(left, right)
        let pair = SavedSync(left: URL(fileURLWithPath: "/left"), right: URL(fileURLWithPath: "/right"), mode: .twoWay)
        func preview(_ count: Int) -> SyncPreview {
            .init(
                pair: pair, left: left, right: right, comparison: comparison,
                plan: .init(steps: (0..<count).map { .init(path: "\($0)", target: .left, action: .trash) }), firstTwoWay: false)
        }
        #expect(!preview(20).requiresDeletionReview)
        #expect(preview(21).requiresDeletionReview)
        var many = preview(21); many.left.entries = (0..<210).map { .init(path: "\($0)") }
        #expect(!many.requiresDeletionReview)  // Exactly 10%, not more than 10%.
    }
}

@MainActor @Suite(.isolatedSettings, .serialized)
struct AsyncPlanEnqueueTests {
    @Test func persistenceFailurePreventsExecutionAndCompletionRunsOnMain() async throws {
        let scratch = try Scratch("async-plan-failure")
        let blocker = scratch.path("blocker")
        try Data().write(to: blocker)
        let controller = makeController(ScriptedUI())
        controller.planJournals = PlanJournalStore(folder: blocker.appendingPathComponent("plans"))
        let journal = PlanJournal(title: "Must not run", steps: [.init(id: "1", title: "copy", payload: Data())])
        let executed = LockedCounter()
        var result: Result<Activity, Error>?
        controller.enqueuePlanAsync(journal, execute: { _, _ in executed.increment() }) { value in
            #expect(Thread.isMainThread); result = value
        }
        #expect(await eventually(5) { result != nil })
        if case .success = result { Issue.record("Persistence failure unexpectedly queued an operation") }
        #expect(executed.value == 0)
        #expect(controller.activities.isEmpty)
    }
    @Test func duplicatePendingIDIsRejectedBeforeItsJournalCanBeOverwritten() async throws {
        let scratch = try Scratch("async-plan-duplicate")
        let controller = makeController(ScriptedUI())
        controller.planJournals = PlanJournalStore(folder: scratch.path("plans"))
        controller.history = OperationHistory(file: scratch.path("history"))
        let journal = PlanJournal(title: "One operation", steps: [.init(id: "1", title: "copy", payload: Data())])
        let executed = LockedCounter()
        var activity: Activity?, rejected = false
        controller.enqueuePlanAsync(journal, execute: { _, _ in executed.increment() }) { result in activity = try? result.get() }
        controller.enqueuePlanAsync(journal, execute: { _, _ in Issue.record("Duplicate executor ran") }) { result in
            if case .failure = result { rejected = true }
        }
        #expect(rejected)
        #expect(await eventually(5) { activity?.state == .completed })
        #expect(executed.value == 1)
        #expect(await eventually(5) { controller.history.entries().count == 1 })
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
