import CryptoKit
import Foundation
import PorpoiseCore

/// A persistent local archive address: the file path is a query item, the entry path is the URL path.
/// Entry names containing ?, #, %, Unicode or spaces round-trip without becoming URL syntax.
public struct ArchiveLocation {
    public let archive: URL
    public let path: String
    public init(archive: URL, path: String = "") { self.archive = archive.standardizedFileURL; self.path = path }
    public init?(url: URL) {
        guard url.scheme == "archive", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let file = components.queryItems?.first(where: { $0.name == "file" })?.value, file.hasPrefix("/")
        else { return nil }
        self.init(archive: URL(fileURLWithPath: file), path: String(url.path.drop(while: { $0 == "/" })))
        guard self.url.host == url.host else { return nil }
    }
    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "archive"
        parts.host = SHA256.hash(data: Data(archive.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        parts.path = "/" + path
        parts.queryItems = [URLQueryItem(name: "file", value: archive.path)]
        return parts.url!
    }
}

/// Archives expose listing and copy-out only. Unsupported writes fail before changing either the archive or
/// the destination. Each provider retains one version's in-memory index, protected across parallel views.
final class ArchiveProvider: RemoteProvider {
    let archive: URL
    private let lock = NSLock()
    private weak var cached: ArchiveIndexSnapshot?
    init(archive: URL) { self.archive = archive }

    func index(checkpoint: () throws -> Void = {}) throws -> ArchiveIndex {
        try lock.withLock {
            if let cached, ArchiveVersion.at(archive) == cached.index.version {
                ArchiveIndexRetention.keep(cached)
                return cached.index
            }
            let index = try ArchiveIndex(archive, checkpoint: checkpoint)
            let snapshot = ArchiveIndexSnapshot(index)
            cached = snapshot
            ArchiveIndexRetention.keep(snapshot)
            return index
        }
    }
    private func location(_ url: URL) throws -> ArchiveLocation {
        guard let location = ArchiveLocation(url: url), location.archive == archive else { throw CocoaError(.fileReadInvalidFileName) }
        return location
    }
    func list(_ folder: URL) throws -> [FileItem] {
        let location = try location(folder)
        return try index().list(location.path, at: ArchiveLocation(archive: archive).url)
    }
    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let location = try location(remote)
        guard !location.path.isEmpty else { throw RemoteError.unsupported("Choose an entry to extract from the archive.") }
        let control = Shell.currentTransferControl
        let checkpoint: () throws -> Void = { try control?.check() }
        return try index(checkpoint: checkpoint).extract(location.path, into: localFolder, name: remote.lastPathComponent, checkpoint: checkpoint)
    }
    /// Opening is a fresh copy, so a changed archive never reopens stale bytes from a remote edit session.
    func localCopy(_ remote: URL, context: CloudTransferContext, policy: TransferPolicy) async throws -> URL {
        let control = JobControl(policy: policy)
        let folder = Settings.cachesFolder.appendingPathComponent("archive-open/" + UUID().uuidString)
        return try await withTaskCancellationHandler {
            try await context.checkpoint()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue(label: "porpoise.archive-open").async {
                    do {
                        let total = try self.index { try control.checkpoint() }.entries[try self.location(remote).path]?.size ?? 0
                        var bytes: Int64 = 0
                        let transport = control.asTransferControl(
                            onBytes: { delta in
                                bytes += delta; context.progress(bytes, max(1, total))
                            }, onStatus: context.status)
                        let local = try Shell.withTransferControl(transport) { try self.download(remote, into: folder) }
                        continuation.resume(returning: local)
                    } catch {
                        try? FileManager.default.removeItem(at: folder)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }
    private func readOnly() throws { throw RemoteError.unsupported("Archives are read-only. Extract an item to change it.") }
    func upload(_ local: URL, into remoteFolder: URL) throws { try readOnly() }
    func delete(_ remote: [URL]) throws { try readOnly() }
    func makeFolder(_ remote: URL) throws { try readOnly() }
    func rename(_ remote: URL, to newName: String) throws { try readOnly() }
    func move(_ remote: [URL], into folder: URL) throws { try readOnly() }
    func copy(_ remote: [URL], into folder: URL) throws { try readOnly() }
    func rootTitle(_ url: URL) -> String { archive.lastPathComponent }
}

/// Providers are kept by RemoteFS for session URLs. Keep at most two large indexes alive across providers;
/// an active listing/extraction owns its own value until it finishes, even after eviction.
private final class ArchiveIndexSnapshot {
    let index: ArchiveIndex
    init(_ index: ArchiveIndex) { self.index = index }
}
private enum ArchiveIndexRetention {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recent: [ArchiveIndexSnapshot] = []
    static func keep(_ snapshot: ArchiveIndexSnapshot) {
        lock.withLock {
            recent.removeAll { $0 === snapshot }
            recent.append(snapshot)
            if recent.count > 2 { recent.removeFirst(recent.count - 2) }
        }
    }
}

/// A cancellable archive listing; leaving a huge archive drops both work and any queued delivery.
final class ArchiveSource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }
    var traits: LocationTraits { LocationTraits(prunesSelection: true, clearsCurrentItem: true) }
    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        let cancellation = ArchiveCancellation()
        DispatchQueue.global(qos: .userInitiated).async {
            var result = LocationListing()
            do {
                guard let provider = RemoteFS.provider(for: folder) as? ArchiveProvider, let loc = ArchiveLocation(url: folder) else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                let index = try provider.index { try cancellation.check() }
                let root = ArchiveLocation(archive: loc.archive).url
                result.items = try index.list(loc.path, at: root)
                var children: [URL: [FileItem]] = [:]
                for url in expanded {
                    try cancellation.check()
                    if let child = ArchiveLocation(url: url), child.archive == loc.archive { children[url] = try index.list(child.path, at: root) }
                }
                result.children = children
            } catch { result.error = .provider(error.localizedDescription) }
            if (try? cancellation.check()) == nil { return }
            DispatchQueue.main.async {
                if (try? cancellation.check()) != nil { deliver(result) }
            }
        }
        return LocationLoad { cancellation.cancel() }
    }
}

private final class ArchiveCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}
