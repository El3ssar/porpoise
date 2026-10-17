import Darwin
import Foundation

/// One account's verified bytes. Durable edit sessions live elsewhere and hold entries against eviction.
public actor CloudOfflineStore {
    public nonisolated let directory: URL
    public nonisolated let source: CloudContentSource
    private var index: CloudOfflineIndex
    private var progress: [String: Double] = [:]
    private var errors: [String: String] = [:]
    private struct Flight { let id: UUID; let task: Task<URL, Error> }
    private var inFlight: [String: Flight] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private var limit: Int64?
    private let freeSpace: @Sendable () -> (available: Int64, total: Int64)
    private let held: @Sendable (CloudItemRef) async -> Bool
    private let changed: @Sendable (CloudOfflineSnapshot) -> Void

    public init(
        source: CloudContentSource, directory: URL, recentLimit: Int64? = 5_000_000_000,
        freeSpace: (@Sendable () -> (available: Int64, total: Int64))? = nil,
        held: @escaping @Sendable (CloudItemRef) async -> Bool = { _ in false },
        changed: @escaping @Sendable (CloudOfflineSnapshot) -> Void = { _ in }
    ) throws {
        self.source = source; self.directory = directory; self.limit = recentLimit
        self.held = held; self.changed = changed
        self.freeSpace =
            freeSpace ?? {
                let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
                return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
            }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var root = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        let file = directory.appendingPathComponent("index.json")
        var loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CloudOfflineIndex.self, from: $0) }
        if loaded?.version != 1 { loaded = nil }
        var recovered = loaded ?? CloudOfflineIndex()
        recovered.entries = recovered.entries.filter { _, entry in
            let url = directory.appendingPathComponent(entry.path).standardizedFileURL
            guard url.path.hasPrefix(directory.standardizedFileURL.path + "/objects/"),
                let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return false }
            return Int64(size) == entry.size
        }
        // A corrupt index has no trusted ownership records. All disposable objects can be rebuilt.
        if loaded == nil { try? fm.removeItem(at: directory.appendingPathComponent("objects")) }
        self.index = recovered
    }

    public func snapshot() -> CloudOfflineSnapshot {
        CloudOfflineSnapshot(entries: index.entries, items: index.items, pins: index.pins, progress: progress, errors: errors)
    }
    public func publish() { changed(snapshot()) }
    public func state(_ ref: CloudItemRef) -> CloudOfflineState {
        if let reason = errors[ref.item] { return .error(reason) }
        if let fraction = progress[ref.item] { return .downloading(fraction) }
        if snapshot().isKept(ref.item) { return .kept }
        return index.entries[ref.item] == nil ? .cloudOnly : .downloaded
    }
    public func usage() -> CloudOfflineUsage { snapshot().usage }
    public func remember(_ items: [CloudRemoteItem]) throws {
        for item in items {
            guard item.ref.account == source.accountID else { throw CloudContentError.unsupported }; index.items[item.ref.item] = item
        }
        try persist()
    }
    public func localCopy(_ ref: CloudItemRef, revision: String?) throws -> URL? {
        guard ref.account == source.accountID, var entry = index.entries[ref.item], entry.item.revision == revision else { return nil }
        let url = directory.appendingPathComponent(entry.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index.entries[ref.item] = nil; try persist(); return nil
        }
        entry.lastUsed = Date(); index.entries[ref.item] = entry; try persist()
        return url
    }
    public func fetch(
        _ item: CloudRemoteItem, keep: Bool = false,
        progress report: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> URL {
        guard item.ref.account == source.accountID, !item.isFolder, item.canDownload else { throw CloudContentError.unsupported }
        index.items[item.ref.item] = item
        if keep { index.pins.insert(item.ref.item) }
        try persist()
        if index.entries[item.ref.item]?.item.export == item.export,
            let copy = try localCopy(item.ref, revision: item.revision)
        {
            try persist(); return copy
        }
        while let running = inFlight[item.ref.item] {
            let result = try await running.task.value
            // An earlier revision's flight must finish before starting the requested revision.
            if index.entries[item.ref.item]?.item.revision == item.revision { return result }
            if inFlight[item.ref.item]?.id == running.id { inFlight[item.ref.item] = nil }
        }
        let epoch = generation
        let task = Task { try await self.performFetch(item, epoch: epoch, report: report) }
        let flightID = UUID()
        inFlight[item.ref.item] = Flight(id: flightID, task: task)
        defer { if inFlight[item.ref.item]?.id == flightID { inFlight[item.ref.item] = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
    private func performFetch(
        _ item: CloudRemoteItem, epoch: Int,
        report: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        await acquire()
        defer { release(); progress[item.ref.item] = nil; publish() }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard !source.isOffline else { throw CloudContentError.offline }
        do { try await makeSpace(item.size ?? 0) } catch { errors[item.ref.item] = error.localizedDescription; publish(); throw error }
        let folder = directory.appendingPathComponent("objects").appendingPathComponent(cloudObjectKey(item.ref.item))
            .appendingPathComponent(cloudObjectKey((item.revision ?? "") + ":" + (item.export ?? "")))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = folder.appendingPathComponent(".partial")
        progress[item.ref.item] = 0; errors[item.ref.item] = nil; publish()
        do {
            try await source.download(item, to: partial) { [weak self] bytes, total in
                report(bytes, total)
                Task { await self?.setProgress(item.ref.item, bytes: bytes, total: total) }
            }
            try Task.checkCancellation()
            guard generation == epoch else { throw CancellationError() }
            return try await adopt(file: partial, as: item)
        } catch {
            if (error as? CloudContentError) == .checksum || (error as? CloudContentError) == .changed {
                try? FileManager.default.removeItem(at: partial)
            }
            errors[item.ref.item] = error.localizedDescription; publish(); throw error
        }
    }
    private func setProgress(_ id: String, bytes: Int64, total: Int64?) {
        guard progress[id] != nil else { return }
        progress[id] = total.flatMap { $0 > 0 ? min(1, Double(bytes) / Double($0)) : nil } ?? 0
        publish()
    }
    public func adopt(file: URL, as item: CloudRemoteItem) async throws -> URL {
        guard item.ref.account == source.accountID, !item.isFolder,
            !item.name.isEmpty, item.name != ".", item.name != "..",
            !item.name.contains("/"), !item.name.contains("\\"), !item.name.contains("\0")
        else { throw CloudContentError.unsupported }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard (item.size == nil || item.export != nil || item.size == size), try item.checksum?.verify(file) != false else {
            throw CloudContentError.checksum
        }
        let relative =
            "objects/" + cloudObjectKey(item.ref.item) + "/" + cloudObjectKey((item.revision ?? "") + ":" + (item.export ?? "")) + "/" + item.name
        let target = directory.appendingPathComponent(relative)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try cloudClone(file, to: staged)
        defer { try? fm.removeItem(at: staged) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let handle = try FileHandle(forWritingTo: staged); try handle.synchronize(); try handle.close()
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: target)
        }
        let previous = index.entries[item.ref.item]
        index.items[item.ref.item] = item
        index.entries[item.ref.item] = CloudOfflineEntry(item: item, path: relative, size: size, lastUsed: Date())
        errors[item.ref.item] = nil
        try persist()
        if let previous, previous.path != relative {
            try? fm.removeItem(at: directory.appendingPathComponent(previous.path).deletingLastPathComponent())
        }
        if file.lastPathComponent == ".partial" { try? fm.removeItem(at: file) }
        try await trim(excluding: item.ref.item)
        return target
    }
    public func pin(_ refs: [CloudItemRef]) throws {
        for ref in refs where ref.account == source.accountID { index.pins.insert(ref.item) }
        try persist()
    }
    public func unpin(_ refs: [CloudItemRef]) async throws {
        for ref in refs where ref.account == source.accountID { index.pins.remove(ref.item) }
        try persist(); try await trim()
    }
    public func remove(_ refs: [CloudItemRef], unpin: Bool = true) async throws {
        for ref in refs where ref.account == source.accountID {
            guard !(await held(ref)) else { throw CloudContentError.heldForEditing }
            if unpin, snapshot().inheritedPin(ref.item) != nil {
                throw CloudContentError.unavailable("Kept because a parent folder is kept downloaded.")
            }
            inFlight[ref.item]?.task.cancel()
            if unpin { index.pins.remove(ref.item) }
            if let entry = index.entries.removeValue(forKey: ref.item) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.path).deletingLastPathComponent())
            }
            errors[ref.item] = nil
        }
        try persist()
    }
    /// Provider removals drop metadata and pin intent as well as bytes. Held edits remain available for conflict UI.
    public func forget(_ refs: [CloudItemRef]) async throws {
        for ref in refs where ref.account == source.accountID {
            if await held(ref) { continue }
            try await remove([ref], unpin: false)
            index.items[ref.item] = nil; index.pins.remove(ref.item)
        }
        try persist()
    }
    public func setRecentLimit(_ bytes: Int64?) async throws { limit = bytes; try await trim() }
    public func removeRecent() async throws {
        let refs = index.entries.values.filter { !snapshot().isKept($0.item.ref.item) }.map(\.item.ref)
        for ref in refs where !(await held(ref)) { try await remove([ref]) }
    }
    public func space() -> (available: Int64, reserve: Int64) {
        let values = freeSpace(); return (values.available, max(2_000_000_000, values.total / 20))
    }
    private func makeSpace(_ bytes: Int64) async throws {
        var values = space()
        if bytes > max(0, values.available - values.reserve) { try await removeRecent(); values = space() }
        guard bytes <= max(0, values.available - values.reserve) else { throw CloudContentError.lowSpace }
    }
    private func trim(excluding: String? = nil) async throws {
        guard let limit else { return }
        for entry in index.entries.values.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard snapshot().usage.recent > limit else { break }
            guard entry.item.ref.item != excluding, !snapshot().isKept(entry.item.ref.item), !(await held(entry.item.ref)) else { continue }
            try await remove([entry.item.ref])
        }
    }
    public func wipe() throws {
        generation += 1
        for flight in inFlight.values { flight.task.cancel() }
        index = CloudOfflineIndex(); progress = [:]; errors = [:]
        try FileManager.default.removeItem(at: directory)
        publish()
    }
    private func persist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("index.json")
        try JSONEncoder().encode(index).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        publish()
    }
}

/// APFS clones retain independent inodes and copy-on-write bytes. Other filesystems get an ordinary copy.
func cloudClone(_ source: URL, to target: URL) throws {
    let cloned = source.withUnsafeFileSystemRepresentation { from in
        target.withUnsafeFileSystemRepresentation { to in
            guard let from, let to else { return false }
            return clonefile(from, to, 0) == 0
        }
    }
    if !cloned { try FileManager.default.copyItem(at: source, to: target) }
}
