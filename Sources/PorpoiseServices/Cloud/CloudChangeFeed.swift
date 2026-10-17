import Foundation

struct CloudChangePage {
    var cursor: String
    var hasMore: Bool
    var apply: () throws -> Void
}
struct CloudChangePoll {
    var changes: Bool
    var backoff: TimeInterval
}
struct CloudChangeSource {
    var scopes: () -> [String]
    var cursor: (String) -> String?
    var setCursor: (String?, String) -> Void
    var initialize: (String) async throws -> String?
    var page: (String, String?) async throws -> CloudChangePage
    var isReset: (Error) -> Bool
    var reset: (String) async throws -> Void
    var waitNeedsCursor: Bool
    var wait: () async throws -> CloudChangePoll
    var invalidPage: Error
    var joinedCheck: () -> Void = {}
}

/// Owns polling and page ordering for each account/namespace. Concurrent checks await the same flight.
public actor CloudChangeFeed {
    private let source: CloudChangeSource
    private var task: Task<Void, Never>?
    private var flight: (UUID, Task<Void, Error>)?
    private var stopping: Task<Void, Never>?
    private var wantsPolling = false
    private var pollingGeneration = 0
    private var interval: TimeInterval?
    private var nextPoll = Date.distantPast
    init(source: CloudChangeSource) { self.source = source }

    public func check() async throws {
        guard stopping == nil else { throw CancellationError() }
        if let flight { source.joinedCheck(); return try await flight.1.value }
        let id = UUID(), task = Task { try await self.applyPages() }
        flight = (id, task)
        defer { if flight?.0 == id { flight = nil } }
        try await task.value
    }
    private func applyPages() async throws {
        for scope in source.scopes() {
            var cursor = source.cursor(scope), seen = Set<String>(), resets = 0
            while true {
                try Task.checkCancellation()
                if cursor == nil, let initial = try await source.initialize(scope) {
                    cursor = initial; source.setCursor(initial, scope)
                }
                let page: CloudChangePage
                do { page = try await source.page(scope, cursor) } catch  where source.isReset(error) {
                    resets += 1
                    guard resets <= 1 else { throw source.invalidPage }
                    try await source.reset(scope)
                    cursor = source.cursor(scope); seen.removeAll(); continue
                }
                try Task.checkCancellation()
                // A page is idempotent; its cursor is durable only after its metadata and emitted changes apply.
                try page.apply(); source.setCursor(page.cursor, scope)
                if !page.hasMore { break }
                guard seen.insert(page.cursor).inserted else { throw source.invalidPage }
                cursor = page.cursor
            }
        }
    }
    public func pollOnce() async throws -> Bool {
        if source.waitNeedsCursor, source.scopes().contains(where: { source.cursor($0) == nil }) { try await check() }
        let delay = nextPoll.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        let poll: CloudChangePoll
        do { poll = try await source.wait() } catch  where source.isReset(error) {
            for scope in source.scopes() { try await source.reset(scope) }
            try await check(); return true
        }
        nextPoll = Date().addingTimeInterval(max(0, interval ?? poll.backoff))
        if poll.changes { try await check() }
        return poll.changes
    }
    public func start() {
        wantsPolling = true
        guard task == nil, stopping == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { _ = try await self.pollOnce() } catch {
                    if Task.isCancelled || error is CancellationError { return }; try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
    /// Synchronous client facades submit generations so a delayed start cannot overtake a newer stop.
    func setPolling(_ active: Bool, generation: Int, interval: TimeInterval) async {
        guard generation >= pollingGeneration else { return }
        pollingGeneration = generation; self.interval = interval
        if active { start() } else { await stop() }
    }
    /// Drains owned requests before callers wipe caches; another start during the drain runs afterwards.
    public func stop() async {
        wantsPolling = false
        if let stopping { await stopping.value; return }
        let running = task, applying = flight?.1
        task = nil; flight = nil
        running?.cancel(); applying?.cancel()
        let drain = Task {
            await running?.value; _ = try? await applying?.value
        }
        stopping = drain; await drain.value; stopping = nil
        if wantsPolling { start() }
    }
}
