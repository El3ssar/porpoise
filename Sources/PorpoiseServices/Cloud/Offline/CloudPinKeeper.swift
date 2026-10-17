import Foundation

/// Reconciles provider metadata with pins. The store enforces a two-download account-wide ceiling.
public actor CloudPinKeeper {
    public let store: CloudOfflineStore
    private let source: CloudContentSource
    private var retry: Task<Void, Never>?
    private var paused = false
    private var working = false
    private var needsReconcile = false

    public init(store: CloudOfflineStore) { self.store = store; self.source = store.source }
    public func start() async {
        source.onChanges = { [weak self] batch in Task { await self?.apply(batch) } }
        await reconcile()
    }
    public func pause() { paused = true; retry?.cancel() }
    public func resume() async { paused = false; await reconcile() }
    public func stop() { paused = true; retry?.cancel(); source.onChanges = nil }

    public func descendants(_ roots: [CloudItemRef]) async throws -> [CloudRemoteItem] {
        var pending = roots
        var seen: Set<CloudItemRef> = []
        var result: [CloudRemoteItem] = []
        while !pending.isEmpty {
            try Task.checkCancellation()
            let refs = Array(pending.prefix(4)); pending.removeFirst(refs.count)
            let fresh = try await withThrowingTaskGroup(of: (CloudRemoteItem, [CloudRemoteItem]).self) { group in
                for ref in refs where seen.insert(ref).inserted {
                    group.addTask { [source] in
                        let item: CloudRemoteItem
                        do { item = try await source.item(ref) } catch CloudContentError.notFound {
                            try await self.store.remove([ref], unpin: false)
                            return (CloudRemoteItem(ref: ref, name: "", isFolder: true), [])
                        }
                        return (item, item.isFolder ? try await source.children(ref) : [])
                    }
                }
                var values: [(CloudRemoteItem, [CloudRemoteItem])] = []
                for try await pair in group { values.append(pair) }
                return values
            }
            for (item, children) in fresh {
                if item.name.isEmpty { continue }
                result.append(item)
                try await store.remember([item] + children)
                pending += children.map(\.ref).filter { !seen.contains($0) }
            }
        }
        return result
    }
    public func download(_ items: [CloudRemoteItem]) async throws {
        let files = items.filter { !$0.isFolder }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                func enqueue(_ item: CloudRemoteItem) {
                    group.addTask { [store] in _ = try await store.fetch(item) }
                }
                while next < min(2, files.count) { enqueue(files[next]); next += 1 }
                while try await group.next() != nil {
                    try Task.checkCancellation()
                    if next < files.count { enqueue(files[next]); next += 1 }
                }
            }
        } catch {
            if (error as? CloudContentError) == .lowSpace || (error as? CloudContentError) == .offline { scheduleRetry() }
            throw error
        }
    }
    public func apply(_ batch: CloudChangeBatch) async {
        do {
            try await store.remember(batch.changed)
            try await store.remove(batch.removed.map { CloudItemRef(account: source.accountID, item: $0) }, unpin: false)
            if batch.reset { await reconcile(); return }
            let snapshot = await store.snapshot()
            let kept = batch.changed.filter { snapshot.isKept($0.ref.item) }
            let expanded = try await descendants(kept.map(\.ref))
            try await download(expanded)
        } catch { scheduleRetry() }
    }
    public func reconcile() async {
        guard !paused else { return }
        if working { needsReconcile = true; return }
        working = true
        defer { working = false }
        repeat {
            needsReconcile = false
            do {
                let before = await store.snapshot()
                let roots = before.pins.map { CloudItemRef(account: source.accountID, item: $0) }
                let items = try await descendants(roots)
                let found = Set(items.map { $0.ref.item })
                // A reset can lose removal events. Probe formerly kept entries absent from the walk:
                // moved items become recent; deleted items lose their bytes.
                for entry in before.entries.values where before.isKept(entry.item.ref.item) && !found.contains(entry.item.ref.item) {
                    do { let fresh = try await source.item(entry.item.ref); try await store.remember([fresh]) } catch CloudContentError.notFound {
                        try await store.remove([entry.item.ref], unpin: false)
                    }
                }
                try await download(items)
            } catch { scheduleRetry() }
        } while needsReconcile && !paused
    }
    private func scheduleRetry() {
        guard !paused, retry == nil else { return }
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            await self?.retryNow()
        }
    }
    private func retryNow() async { retry = nil; await reconcile() }
}
