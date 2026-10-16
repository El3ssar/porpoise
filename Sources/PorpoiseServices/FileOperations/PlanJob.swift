import Darwin
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
    /// Publish a baseline only after its generation-specific log exists. Recovery never treats an unreadable
    /// or missing progress log as an empty one, which could repeat completed operations.
    private struct Baseline: Codable {
        var formatVersion = 3
        let generation: UUID
        let journal: PlanJournal
    }
    private struct Event: Codable {
        let generation: UUID
        let index: Int
        let state: PlanJournal.Step.State
        let checkpoint: Data?
    }
    private struct OpenJournal {
        let generation: UUID
        let descriptor: Int32
        let count: Int
    }
    private var openJournals: [UUID: OpenJournal] = [:]
    private let appendEvent: (Int32, Data) throws -> Void

    public convenience init(folder: URL) { self.init(folder: folder, appendEvent: Self.appendAll) }
    init(folder: URL, appendEvent: @escaping (Int32, Data) throws -> Void) {
        self.folder = folder; self.appendEvent = appendEvent
    }
    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }
    private func eventsURL(_ id: UUID, _ generation: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString + "." + generation.uuidString + ".events")
    }
    private func eventFiles(_ id: UUID) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix(id.uuidString + ".") && $0.pathExtension == "events"
        }
    }

    public func save(_ journal: PlanJournal) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let baseline = Baseline(generation: UUID(), journal: journal)
            let log = eventsURL(journal.id, baseline.generation)
            let descriptor = open(log.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            do { try JSONEncoder().encode(baseline).write(to: url(journal.id), options: .atomic) } catch {
                close(descriptor); try? FileManager.default.removeItem(at: log); throw error
            }
            if let previous = openJournals.removeValue(forKey: journal.id) { close(previous.descriptor) }
            openJournals[journal.id] = OpenJournal(generation: baseline.generation, descriptor: descriptor, count: journal.steps.count)
            // The new baseline already points at its own log. Orphans left by a prior crash are harmless.
            for previous in (try? eventFiles(journal.id)) ?? [] where previous.lastPathComponent != log.lastPathComponent {
                try? FileManager.default.removeItem(at: previous)
            }
        }
    }
    /// Appends only the current step. A partial final write is ignored during replay, leaving the last durable
    /// state (usually running) for the executor's existing physical postcondition reconciliation.
    func saveStep(_ id: UUID, index: Int, state: PlanJournal.Step.State, checkpoint: Data?) throws {
        try lock.withLock {
            guard let journal = openJournals[id], (0..<journal.count).contains(index), state != .pending else {
                throw FileOperationError.failed("This checkpoint does not match an open plan journal.")
            }
            let event = Event(generation: journal.generation, index: index, state: state, checkpoint: checkpoint)
            var data = try JSONEncoder().encode(event); data.append(10)
            do { try appendEvent(journal.descriptor, data) } catch {
                // Never append behind a possibly torn record. A new run must first replay and compact it.
                openJournals.removeValue(forKey: id); close(journal.descriptor)
                throw error
            }
        }
    }
    private static func appendAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }
    public func remove(_ id: UUID) throws {
        try lock.withLock {
            if let journal = openJournals.removeValue(forKey: id) { close(journal.descriptor) }
            // Remove the baseline first. An orphan log is ignored; a baseline without its completed log could
            // otherwise resurrect already completed operations after a crash between these two unlinks.
            if FileManager.default.fileExists(atPath: url(id).path) { try FileManager.default.removeItem(at: url(id)) }
            if FileManager.default.fileExists(atPath: folder.path) {
                for log in try eventFiles(id) { try FileManager.default.removeItem(at: log) }
            }
        }
    }
    /// Unknown or damaged journals are retained on disk and never executed automatically. Version-one whole
    /// journals still load; the next run compacts their recovered state into one generation-tagged baseline.
    public func all() throws -> [PlanJournal] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    let decoder = JSONDecoder()
                    guard let baseline = try? decoder.decode(Baseline.self, from: data) else {
                        guard let legacy = try? decoder.decode(PlanJournal.self, from: data), legacy.version == 1 else { return nil }
                        return legacy
                    }
                    guard [2, 3].contains(baseline.formatVersion), baseline.journal.version == 1 else { return nil }
                    var journal = baseline.journal
                    let log =
                        baseline.formatVersion == 2
                        ? folder.appendingPathComponent(journal.id.uuidString + ".events") : eventsURL(journal.id, baseline.generation)
                    guard let events = try? Data(contentsOf: log) else { return nil }
                    // Both an empty final slice (normal newline) and an incomplete final slice are excluded.
                    for line in events.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
                        guard let event = try? decoder.decode(Event.self, from: Data(line)) else { return nil }
                        guard event.generation == baseline.generation else { continue }
                        guard journal.steps.indices.contains(event.index), event.state != .pending else { return nil }
                        let prior = journal.steps[event.index].state
                        guard event.state == .running ? prior != .completed : prior != .pending else { return nil }
                        journal.steps[event.index].state = event.state
                        journal.steps[event.index].checkpoint = event.checkpoint
                    }
                    return journal
                }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }
    deinit { for journal in openJournals.values { close(journal.descriptor) } }
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
    private var completedStepIDs: [String]

    public init(journal: PlanJournal, store: PlanJournalStore) {
        self.journal = journal
        title = journal.title
        self.store = store
        completedStepIDs = journal.steps.filter { $0.state == .completed }.map { $0.operation.id }
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
        try store.saveStep(journal.id, index: index, state: .running, checkpoint: data)
        journal.steps[index].checkpoint = data
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
                completedSteps: completedStepIDs.count, totalSteps: journal.steps.count,
                currentTitle: journal.steps[index].operation.title, stepFraction: fraction.isFinite ? max(0, min(1, fraction)) : 0,
                completedStepIDs: completedStepIDs))
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
            try store.saveStep(journal.id, index: index, state: .running, checkpoint: journal.steps[index].checkpoint)
            journal.steps[index].state = .running
            publish(index: index, fraction: 0)
            try execute(journal.steps[index].operation, context)
            // An executor that returns successfully has finished the step, even if interruption arrived meanwhile.
            try store.saveStep(journal.id, index: index, state: .completed, checkpoint: nil)
            journal.steps[index].state = .completed
            journal.steps[index].checkpoint = nil
            completedStepIDs.append(journal.steps[index].operation.id)
            publish(index: index, fraction: 0, force: index == journal.steps.count - 1)

        }
        try store.remove(journal.id)
    }
}
