import Foundation
import PorpoiseCore

/// An engine-defined operation. Payloads must be versioned by their engine and must not contain credentials.
public struct PlanStep: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let payload: Data

    public init(id: String, title: String, payload: Data) {
        self.id = id
        self.title = title
        self.payload = payload
    }
}

/// Durable ordered plan. A running step is reconciled by its executor after a crash; completed steps are skipped.
public struct PlanJournal: Codable, Equatable, Sendable, Identifiable {
    public struct Step: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case pending, running, completed }
        public let operation: PlanStep
        public var state: State = .pending
        public var checkpoint: Data?
    }

    public var version = 1
    public let id: UUID
    public let title: String
    public var steps: [Step]

    public init(id: UUID = UUID(), title: String, steps: [PlanStep]) {
        self.id = id
        self.title = title
        self.steps = steps.map { Step(operation: $0) }
    }
}

/// Separate from legacy homogeneous FileJob journals. Writes fail visibly before execution continues.
public final class PlanJournalStore: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()

    public init(folder: URL) { self.folder = folder }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    public func save(_ journal: PlanJournal) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(journal).write(to: url(journal.id), options: .atomic)
        }
    }

    public func remove(_ id: UUID) throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: url(id).path) { try FileManager.default.removeItem(at: url(id)) }
        }
    }

    /// Unknown or damaged journals are retained on disk and never executed automatically.
    public func all() throws -> [PlanJournal] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.compactMap { url in
                    guard let data = try? Data(contentsOf: url), let journal = try? JSONDecoder().decode(PlanJournal.self, from: data),
                        journal.version == 1
                    else { return nil }
                    return journal
                }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }
}

public struct PlanProgress: Sendable {
    public let completedSteps: Int
    public let totalSteps: Int
    public let currentTitle: String
    public let stepFraction: Double
    public var completedStepIDs: [String] = []
    public var fraction: Double { totalSteps == 0 ? 1 : (Double(completedSteps) + stepFraction) / Double(totalSteps) }
}

/// One synchronous executor invocation, on the plan worker thread. Check at safe boundaries and inside long loops.
public final class PlanStepContext {
    private let job: PlanJob
    public let index: Int
    public let wasRunning: Bool
    /// Persisted engine checkpoint, if any. It is updated after a successful save.
    public private(set) var savedCheckpoint: Data?

    fileprivate init(job: PlanJob, index: Int, wasRunning: Bool, checkpoint: Data?) {
        self.job = job
        self.index = index
        self.wasRunning = wasRunning
        savedCheckpoint = checkpoint
    }

    public var isCancelled: Bool { job.isCancelled }
    public func checkCancellation() throws { try job.checkCancellation() }

    /// Save only after the corresponding work is durable. Progress alone is not a recovery checkpoint.
    public func saveCheckpoint(_ data: Data) throws {
        try job.saveCheckpoint(data, index: index)
        savedCheckpoint = data
    }

    /// A fraction within this step, clamped to 0...1. Called from this step's worker thread.
    public func report(fraction: Double) { job.report(index: index, fraction: fraction) }
}

/// Ordered mixed-operation job. Configure callbacks before `run()`, which must run once, off main.
/// Controls are thread safe. Pause takes effect when the executor next calls `checkCancellation()`.
public final class PlanJob: @unchecked Sendable {
    public let title: String
    public let store: PlanJournalStore
    public private(set) var journal: PlanJournal
    public var onProgress: (PlanProgress) -> Void = { _ in }
    public var progressInterval: TimeInterval = 0.25
    private var lastProgress: TimeInterval = -.infinity
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var interrupted = false
    private var ended = false

    public init(journal: PlanJournal, store: PlanJournalStore) {
        self.journal = journal
        title = journal.title
        self.store = store
    }

    public var isCancelled: Bool { condition.withLock { cancelled || interrupted } }
    public var isInterrupted: Bool { condition.withLock { interrupted } }
    public var hasEnded: Bool { condition.withLock { ended } }
    public func pause() { condition.withLock { paused = true } }
    public func resume() {
        condition.withLock {
            paused = false; condition.broadcast()
        }
    }
    public func cancel() {
        condition.withLock {
            cancelled = true; condition.broadcast()
        }
    }
    public func interrupt() {
        condition.withLock {
            interrupted = true; condition.broadcast()
        }
    }

    fileprivate func checkCancellation() throws {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled && !interrupted { condition.wait() }
        if interrupted { throw FileOperationError.interrupted }
        if cancelled { throw FileOperationError.cancelled }
    }

    fileprivate func saveCheckpoint(_ data: Data, index: Int) throws {
        var next = journal
        next.steps[index].checkpoint = data
        try store.save(next)
        journal = next
    }

    fileprivate func report(index: Int, fraction: Double) {
        publish(index: index, fraction: fraction, force: true)
    }

    private func publish(index: Int, fraction: Double, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastProgress >= progressInterval else { return }
        lastProgress = now
        onProgress(
            PlanProgress(
                completedSteps: journal.steps.filter { $0.state == .completed }.count, totalSteps: journal.steps.count,
                currentTitle: journal.steps[index].operation.title, stepFraction: fraction.isFinite ? max(0, min(1, fraction)) : 0,
                completedStepIDs: journal.steps.filter { $0.state == .completed }.map { $0.operation.id }))
    }

    /// A crash between the physical operation and saving completion leaves a running step. The executor must
    /// reconcile that step against disk using `wasRunning`/`savedCheckpoint`; arbitrary IO cannot be exactly-once.
    public func run(execute: (PlanStep, PlanStepContext) throws -> Void) throws {
        defer { condition.withLock { ended = true } }
        guard journal.version == 1, Set(journal.steps.map { $0.operation.id }).count == journal.steps.count else {
            throw FileOperationError.failed("This plan has an unsupported version or duplicate step IDs.")
        }
        try store.save(journal)
        for index in journal.steps.indices where journal.steps[index].state != .completed {
            try checkCancellation()
            let context = PlanStepContext(
                job: self, index: index, wasRunning: journal.steps[index].state == .running, checkpoint: journal.steps[index].checkpoint)
            journal.steps[index].state = .running
            try store.save(journal)
            publish(index: index, fraction: 0)
            try execute(journal.steps[index].operation, context)
            // An executor that returns successfully has finished the step, even if interruption arrived meanwhile.
            journal.steps[index].state = .completed
            journal.steps[index].checkpoint = nil
            try store.save(journal)
            publish(index: index, fraction: 0, force: index == journal.steps.count - 1)

        }
        try store.remove(journal.id)
    }
}
