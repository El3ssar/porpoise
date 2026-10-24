import Foundation
import PorpoiseCore

/// The local items handed to a sharing service. Temporary copies live until that service finishes reading them.
public final class PreparedSharingItems: @unchecked Sendable {
    private static let cleanupQueue = SharingCleanupQueue()
    public let urls: [URL]
    let folder: URL?
    private let lock = NSLock()
    private var cleaned = false
    private let lease: SharingStagingLease?

    init(urls: [URL], folder: URL? = nil, lease: SharingStagingLease? = nil) {
        self.urls = urls; self.folder = folder; self.lease = lease
    }
    deinit { cleanup() }

    /// Removing a large staged folder must not block AppKit's sharing delegate callback.
    public func cleanup(after delay: TimeInterval = 0) {
        let remove = lock.withLock {
            guard !cleaned else { return false }
            cleaned = true
            return true
        }
        guard remove, let folder else { return }
        let delay = delay.isFinite ? min(max(0, delay), 24 * 60 * 60) : 0
        Self.cleanupQueue.schedule(folder, after: delay, lease: lease)
    }

    /// After the app cancels its sharing sessions, drain removals off-main, waiting at most ten seconds.
    /// False means there is nothing to wait for; otherwise completion is delivered on the main queue.
    public static func cleanupBeforeQuit(completion: @escaping () -> Void) -> Bool {
        cleanupQueue.finishBeforeQuit(completion: completion)
    }
}

final class SharingCleanupQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "porpoise.sharing-cleanup", qos: .utility)
    private let lock = NSLock()
    private typealias Removal = (remove: @Sendable () -> Void, work: DispatchWorkItem)
    private var pending: [UUID: Removal] = [:]
    private var finishing: UUID?
    private var completions: [() -> Void] = []
    private let remove: @Sendable (URL) -> Void

    init(remove: @escaping @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) { self.remove = remove }

    func schedule(_ folder: URL, after delay: TimeInterval, lease: SharingStagingLease? = nil) {
        let id = UUID()
        let remove: @Sendable () -> Void = { [remove] in
            if let lease { lease.remove() } else { remove(folder) }
        }
        let work = DispatchWorkItem { [self] in
            remove()
            lock.withLock { _ = pending.removeValue(forKey: id) }
        }
        lock.withLock { pending[id] = (remove, work) }
        // Refresh on the worker, retaining the lease throughout both the grace period and deletion.
        if let lease { queue.async { lease.touch() } }
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func finishBeforeQuit(timeout: TimeInterval = 10, completion: @escaping () -> Void) -> Bool {
        var alreadyFinishing = false
        let id = UUID()
        let removals = lock.withLock {
            if finishing != nil { completions.append(completion); alreadyFinishing = true; return [Removal]() }
            let removals = Array(pending.values)
            if !removals.isEmpty { finishing = id; completions.append(completion) }
            pending.removeAll()
            return removals
        }
        if alreadyFinishing { return true }
        guard !removals.isEmpty else { return false }
        for removal in removals { removal.work.cancel() }
        // Even a blocked filesystem must not hold application termination indefinitely.
        let deadline = timeout.isFinite ? max(0, timeout) : 10
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { self.finished(id) }
        // This queue also runs any timer already deleting a folder.
        queue.async {
            for removal in removals { removal.remove() }
            self.finished(id)
        }
        return true
    }

    private func finished(_ id: UUID) {
        let callbacks = lock.withLock {
            guard finishing == id else { return [() -> Void]() }
            finishing = nil
            let callbacks = completions; completions = []
            return callbacks
        }
        DispatchQueue.main.async { for callback in callbacks { callback() } }
    }
}

public enum SharingPreparation {
    public static let successfulShareRetentionInterval: TimeInterval = 10 * 60

    /// Called after the first window draws. All enumeration and deletion stays on a utility worker.
    public static func sweepStaleCopiesAfterLaunch() {
        DispatchQueue.global(qos: .utility).async {
            SharingStaging.sweep(root: FileManager.default.temporaryDirectory.appendingPathComponent(SharingStaging.rootName, isDirectory: true))
        }
    }

    /// Metadata-only eligibility: no network requests or disk reads during menu validation or drag updates.
    public static func supports(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { $0.isFileURL || LocationKind.of($0).isRemote }
    }

    /// Runs on a worker queue. Each remote source gets its own destination, so equal names never conflict.
    static func prepare(
        _ urls: [URL], control: JobControl, batchID: UUID, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        progress: @escaping (JobProgress) -> Void, notice: @escaping (String?) -> Void
    ) throws -> PreparedSharingItems {
        guard supports(urls) else { throw SharingPreparationError.unsupported }
        try control.checkpoint()
        guard urls.contains(where: { !$0.isFileURL }) else { return PreparedSharingItems(urls: urls) }
        let lease = try SharingStaging.create(in: temporaryDirectory)
        let folder = lease.folder
        var succeeded = false
        defer { if !succeeded { lease.remove() } }
        let accounts = try urls.compactMap { try (RemoteFS.provider(for: $0) as? CloudTransferProvider)?.transferAccount($0) }
        try CloudTransferJournal.shared.claim(batchID, accounts: accounts, control: control)
        defer { CloudTransferJournal.shared.release(batchID) }
        var prepared: [URL] = []
        var completedBytes: Int64 = 0
        for (index, url) in urls.enumerated() {
            try control.checkpoint()
            if url.isFileURL { prepared.append(url); continue }
            let destination = folder.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let job = RemoteTransferJob(
                kind: .copy, sources: [url], destination: destination, control: control, rule: .ask,
                options: TransferCompareOptions(method: .sizeAndDate))
            job.temporaryCopy = true
            job.cloudBatchID = batchID
            job.onNotice = notice
            let priorBytes = completedBytes
            job.onProgress = { snapshot in
                var snapshot = snapshot
                snapshot.doneBytes += priorBytes
                snapshot.totalBytes += priorBytes
                snapshot.totalItems = urls.count
                snapshot.doneItems = index
                progress(snapshot)
            }
            job.run(ownsControl: false)
            try control.checkpoint()
            guard job.errors.isEmpty, job.results.count == 1, let result = job.results.first else {
                throw job.firstError ?? SharingPreparationError.downloadFailed
            }
            // The transfer engine owns publication. Never let a provider hand an unrelated path to a sharing service.
            let root = destination.standardizedFileURL.path + "/"
            guard result.isFileURL, result.standardizedFileURL.path.hasPrefix(root) else { throw SharingPreparationError.downloadFailed }
            try validateLinks(in: result, within: destination)
            completedBytes += job.progress.doneBytes
            prepared.append(result)
        }
        try control.checkpoint()
        lease.touch()
        succeeded = true
        return PreparedSharingItems(urls: prepared, folder: folder, lease: lease)
    }

    /// A remote/archive symlink must not make the native service read an unrelated local path.
    private static func validateLinks(in item: URL, within folder: URL) throws {
        let root = folder.resolvingSymlinksInPath().path + "/"
        func check(_ url: URL) throws {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let target = url.resolvingSymlinksInPath().path
                guard target.hasPrefix(root) else { throw SharingPreparationError.unsafeLink }
            }
        }
        try check(item)
        let properties = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { return }
        var enumerationError: Error?
        if let entries = FileManager.default.enumerator(
            at: item, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
            errorHandler: { _, error in
                enumerationError = error; return false
            })
        {
            for case let url as URL in entries { try check(url) }
        }
        if let enumerationError { throw enumerationError }
    }

}

enum SharingPreparationError: LocalizedError {
    case unsupported, downloadFailed, unsafeLink
    var errorDescription: String? {
        switch self {
        case .unsupported: "These items cannot be shared. Choose files or folders from a local or connected location."
        case .unsafeLink: "A downloaded symbolic link points outside the selected items. Nothing was shared."
        case .downloadFailed: "The selected items could not all be downloaded. Nothing was shared."
        }
    }
}
