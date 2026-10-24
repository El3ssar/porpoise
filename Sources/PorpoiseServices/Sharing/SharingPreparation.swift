import Foundation
import PorpoiseCore

/// The local items handed to a sharing service. Temporary copies live until that service finishes reading them.
public final class PreparedSharingItems: @unchecked Sendable {
    private static let cleanupQueue = SharingCleanupQueue()
    public let urls: [URL]
    let folder: URL?
    private let lock = NSLock()
    private var cleaned = false

    init(urls: [URL], folder: URL? = nil) { self.urls = urls; self.folder = folder }
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
        Self.cleanupQueue.schedule(folder, after: delay)
    }

    /// After the app cancels its sharing sessions, finish pending removals off-main before approving termination.
    /// False means there is nothing to wait for; otherwise completion is delivered on the main queue.
    public static func cleanupBeforeQuit(completion: @escaping () -> Void) -> Bool {
        cleanupQueue.finishBeforeQuit(completion: completion)
    }
}

private final class SharingCleanupQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "porpoise.sharing-cleanup", qos: .utility)
    private let lock = NSLock()
    private var pending: [UUID: (URL, DispatchWorkItem)] = [:]
    private var finishing = false
    private var completions: [() -> Void] = []

    func schedule(_ folder: URL, after delay: TimeInterval) {
        let id = UUID()
        let work = DispatchWorkItem { [self] in
            try? FileManager.default.removeItem(at: folder)
            lock.withLock { _ = pending.removeValue(forKey: id) }
        }
        lock.withLock { pending[id] = (folder, work) }
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func finishBeforeQuit(completion: @escaping () -> Void) -> Bool {
        var alreadyFinishing = false
        let removals = lock.withLock {
            if finishing { completions.append(completion); alreadyFinishing = true; return [(URL, DispatchWorkItem)]() }
            let removals = Array(pending.values)
            if !removals.isEmpty { finishing = true; completions.append(completion) }
            pending.removeAll()
            return removals
        }
        if alreadyFinishing { return true }
        guard !removals.isEmpty else { return false }
        for (_, work) in removals { work.cancel() }
        // This queue also runs any timer already deleting a folder, so completion waits for those removals too.
        queue.async {
            for (folder, _) in removals { try? FileManager.default.removeItem(at: folder) }
            let completions = self.lock.withLock {
                self.finishing = false
                let completions = self.completions; self.completions = []
                return completions
            }
            DispatchQueue.main.async { for completion in completions { completion() } }
        }
        return true
    }
}

public enum SharingPreparation {
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
        let folder = temporaryDirectory.appendingPathComponent("Porpoise-Share-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
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
        succeeded = true
        return PreparedSharingItems(urls: prepared, folder: folder)
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
