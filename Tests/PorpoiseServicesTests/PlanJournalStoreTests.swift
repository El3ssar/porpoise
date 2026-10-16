import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct PlanJournalStoreTests {
    private func journal(count: Int = 2, id: UUID = UUID()) -> PlanJournal {
        PlanJournal(
            id: id, title: "Recovery",
            steps: (0..<count).map {
                PlanStep(id: String($0), title: "Copy \($0)", payload: Data(repeating: UInt8($0 % 255), count: 1024))
            })
    }
    private func path(_ store: PlanJournalStore, _ journal: PlanJournal, _ ext: String) -> URL {
        store.folder.appendingPathComponent(journal.id.uuidString + "." + ext)
    }
    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    @Test func payloadIsWrittenOnceAndReplaySkipsCompletedSteps() throws {
        let scratch = try Scratch(), store = PlanJournalStore(folder: scratch.path("plans")), original = journal(count: 64)
        try store.save(original)
        let immutable = try Data(contentsOf: path(store, original, "json"))
        for index in 0..<20 {
            try store.saveStep(original.id, index: index, state: .running, checkpoint: nil)
            try store.saveStep(original.id, index: index, state: .completed, checkpoint: nil)
        }
        #expect(try Data(contentsOf: path(store, original, "json")) == immutable)
        #expect(try Data(contentsOf: path(store, original, "events")).count < 10_000)
        let reopened = PlanJournalStore(folder: store.folder)
        let recovered = try #require(reopened.all().first)
        #expect(recovered.steps.filter { $0.state == .completed }.count == 20)
        let job = PlanJob(journal: recovered, store: reopened)
        var ran: [String] = [], completed: [String] = []
        job.onProgress = { completed = $0.completedStepIDs }
        try job.run { step, context in
            #expect(!context.wasRunning); ran.append(step.id)
        }
        #expect(ran == (20..<64).map(String.init)); #expect(Set(completed) == Set((0..<64).map(String.init)))
        #expect(try reopened.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).isEmpty)
    }
    @Test func tornFinalAppendPreservesTheLastCompleteCheckpoint() throws {
        let scratch = try Scratch(), store = PlanJournalStore(folder: scratch.path("plans")), original = journal()
        try store.save(original)
        try store.saveStep(original.id, index: 0, state: .running, checkpoint: nil)
        try store.saveStep(original.id, index: 0, state: .completed, checkpoint: nil)
        let saved = Data(repeating: 17, count: 100_000)
        try store.saveStep(original.id, index: 1, state: .running, checkpoint: saved)
        try append(Data("{\"generation\":\"partial".utf8), to: path(store, original, "events"))
        let reopened = PlanJournalStore(folder: store.folder), recovered = try #require(reopened.all().first)
        #expect(recovered.steps[0].state == .completed); #expect(recovered.steps[1].state == .running)
        #expect(recovered.steps[1].checkpoint == saved)
        var ran: [String] = []
        try PlanJob(journal: recovered, store: reopened).run { step, context in
            ran.append(step.id); #expect(context.wasRunning); #expect(context.savedCheckpoint == saved)
        }
        #expect(ran == ["1"]); #expect(try reopened.all().isEmpty)
    }
    @Test func replacedBaselineRejectsThePreviousGenerationsProgress() throws {
        let scratch = try Scratch(), store = PlanJournalStore(folder: scratch.path("plans")), original = journal()
        try store.save(original)
        try store.saveStep(original.id, index: 0, state: .running, checkpoint: nil)
        try store.saveStep(original.id, index: 0, state: .completed, checkpoint: nil)
        let stale = try Data(contentsOf: path(store, original, "events"))
        let replacement = journal(count: 3, id: original.id)
        try store.save(replacement)
        // Simulate a crash after replacing the baseline but before truncating its old sidecar.
        try stale.write(to: path(store, original, "events"))
        #expect(try store.all().first?.steps.allSatisfy { $0.state == .pending } == true)
        try store.saveStep(original.id, index: 0, state: .running, checkpoint: Data("new".utf8))
        let recovered = try #require(store.all().first)
        #expect(recovered.steps.count == 3); #expect(recovered.steps[0].state == .running)
        #expect(recovered.steps[0].checkpoint == Data("new".utf8))
    }
    @Test func corruptCompleteRecordsAndUnknownFormatsAreRetainedWithoutExecution() throws {
        let scratch = try Scratch(), store = PlanJournalStore(folder: scratch.path("plans")), original = journal()
        #expect(try store.all().isEmpty); try store.remove(UUID())
        try store.save(original)
        try append(Data("not-json\n".utf8), to: path(store, original, "events"))
        #expect(try store.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: path(store, original, "json").path))
        try store.save(original)
        try store.saveStep(original.id, index: 0, state: .running, checkpoint: nil)
        let data = try Data(contentsOf: path(store, original, "events"))
        var event = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        event["index"] = 999
        var bad = try JSONSerialization.data(withJSONObject: event); bad.append(10)
        try bad.write(to: path(store, original, "events"))
        #expect(try store.all().isEmpty)
        try store.save(original)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path(store, original, "json"))) as? [String: Any])
        envelope["formatVersion"] = 99
        try JSONSerialization.data(withJSONObject: envelope).write(to: path(store, original, "json"))
        #expect(try store.all().isEmpty)
    }
    @Test func legacyWholeJournalLoadsAndIsCompactedOnResume() throws {
        let scratch = try Scratch(), folder = try scratch.folder("plans"), store = PlanJournalStore(folder: folder)
        var legacy = journal(); legacy.steps[0].state = .completed
        try JSONEncoder().encode(legacy).write(to: path(store, legacy, "json"))
        let recovered = try #require(store.all().first)
        #expect(recovered == legacy)
        var ran: [String] = []
        try PlanJob(journal: recovered, store: store).run { step, _ in ran.append(step.id) }
        #expect(ran == ["1"]); #expect(try store.all().isEmpty)
        var unknown = journal(); unknown.version = 99
        let bytes = try JSONEncoder().encode(unknown); try bytes.write(to: path(store, unknown, "json"))
        #expect(try store.all().isEmpty); #expect(try Data(contentsOf: path(store, unknown, "json")) == bytes)
        try Data("broken".utf8).write(to: folder.appendingPathComponent("damaged.json"))
        #expect(try store.all().isEmpty)
    }
    @Test func appendFailureStopsBeforeExecutionOrCheckpointAcknowledgement() throws {
        let scratch = try Scratch()
        let blocked = PlanJournalStore(folder: scratch.path("blocked")) { _, _ in throw POSIXError(.ENOSPC) }
        let first = PlanJob(journal: journal(), store: blocked)
        var ran = false
        #expect(throws: POSIXError.self) { try first.run { _, _ in ran = true } }
        #expect(!ran); #expect(try blocked.all().first?.steps[0].state == .pending)
        var writes = 0
        let partial = PlanJournalStore(folder: scratch.path("partial")) { descriptor, data in
            writes += 1
            if writes == 2 {
                _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, data.count / 2) }
                throw POSIXError(.ENOSPC)
            }
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, data.count) }
            #expect(written == data.count)
        }
        let job = PlanJob(journal: journal(), store: partial)
        #expect(throws: POSIXError.self) {
            try job.run { _, context in
                try context.saveCheckpoint(Data("not acknowledged".utf8)); ran = true
            }
        }
        #expect(!ran); #expect(job.journal.steps[0].checkpoint == nil)
        let saved = try #require(PlanJournalStore(folder: partial.folder).all().first)
        #expect(saved.steps[0].state == .running); #expect(saved.steps[0].checkpoint == nil)
    }
    @Test func checkpointsMustMatchAnOpenPlanAndARealStep() throws {
        let scratch = try Scratch(), store = PlanJournalStore(folder: scratch.path("plans")), original = journal()
        #expect(throws: FileOperationError.self) { try store.saveStep(original.id, index: 0, state: .running, checkpoint: nil) }
        try store.save(original)
        #expect(throws: FileOperationError.self) { try store.saveStep(original.id, index: 99, state: .running, checkpoint: nil) }
        #expect(throws: FileOperationError.self) { try store.saveStep(original.id, index: 0, state: .pending, checkpoint: nil) }
    }
}
