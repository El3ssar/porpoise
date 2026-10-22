import CryptoKit
import Foundation
import PorpoiseCore

/// Opt-in only: publication must atomically reject a changed remote revision. A metadata check followed by an
/// unconditional upload does not satisfy this contract. Other providers open a durable local copy without save-back.
protocol RemoteEditPublishing: RemoteProvider {
    func editRevision(_ remote: URL) throws -> String
    func publishEdit(_ snapshot: URL, to remote: URL, expectedRevision: String) throws -> String
}

struct RemoteEditSession: Codable, Sendable {
    var version = 1
    var remote: URL
    var name: String
    var sentHash: String
    var revision: String?
    var uploadID: UUID?
    var uploadHash: String?
}

enum RemoteEditError: LocalizedError {
    case damaged, changed, copyOnly
    var errorDescription: String? {
        switch self {
        case .damaged: return "The saved remote editing session could not be read. Its local files have been kept."
        case .changed: return "The file changed while preparing its local copy. Both versions have been kept."
        case .copyOnly: return "This server cannot safely save changes back. Your edited copy stays on this Mac."
        }
    }
}

/// Owns user-edited bytes in Application Support, outside all disposable rendition/download caches. One serial
/// worker owns each store; a retry reads the durable record and reuses the exact upload snapshot after failure.
final class RemoteEditSessionStore: @unchecked Sendable {
    let folder: URL
    let local: URL
    private let remote: URL
    private let queue = DispatchQueue(label: "porpoise.remote-edit", qos: .userInitiated)
    private var recordURL: URL { folder.appendingPathComponent("session.json") }

    private static func canonical(_ remote: URL) -> URL? {
        guard var parts = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return nil }
        parts.password = nil; parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.port == nil {
            switch parts.scheme {
            case "sftp", "ssh": parts.port = 22
            case "ftp", "ftps": parts.port = 21
            default: break
            }
        }
        return parts.url
    }
    static func identity(_ remote: URL) -> String {
        SHA256.hash(data: Data((canonical(remote)?.absoluteString ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(remote: URL, root: URL) {
        // An unparseable location is rejected by open before any directory or provider is touched.
        self.remote = Self.canonical(remote) ?? URL(fileURLWithPath: "/")
        folder = root.appendingPathComponent(Self.identity(remote), isDirectory: true)
        local = folder.appendingPathComponent("Working", isDirectory: true).appendingPathComponent(remote.lastPathComponent)
    }

    func open(provider: RemoteProvider, context: CloudTransferContext = .init()) async throws -> URL {
        try await run(context: context) { control in
            guard !self.remote.isFileURL else { throw RemoteEditError.damaged }
            try RemoteFS.checkName(self.remote.lastPathComponent)
            if let session = try self.load() {
                guard session.remote == self.remote, session.name == self.remote.lastPathComponent,
                    FileManager.default.fileExists(atPath: self.local.path)
                else { throw RemoteEditError.damaged }
                return self.local
            }
            // Never remove or adopt bytes without their record, including a torn initial download.
            guard !FileManager.default.fileExists(atPath: self.local.path) else { throw RemoteEditError.damaged }
            let incoming = self.folder.appendingPathComponent("Opening-" + UUID().uuidString, isDirectory: true)
            try self.create(incoming)
            defer { try? FileManager.default.removeItem(at: incoming) }
            let publisher = provider as? RemoteEditPublishing
            let revision = try publisher?.editRevision(self.remote)
            let downloaded = try provider.download(self.remote, into: incoming)
            try control.checkpoint()
            guard downloaded.deletingLastPathComponent().standardizedFileURL == incoming.standardizedFileURL,
                downloaded.lastPathComponent == self.remote.lastPathComponent,
                (try downloaded.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
                (try downloaded.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
            else { throw RemoteEditError.damaged }
            if let revision, try publisher?.editRevision(self.remote) != revision { throw RemoteEditError.changed }
            try self.create(self.local.deletingLastPathComponent())
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: downloaded.path)
            try FileManager.default.moveItem(at: downloaded, to: self.local)
            try self.sync(self.local)
            try self.syncDirectory(self.local.deletingLastPathComponent())
            try self.save(
                .init(remote: self.remote, name: self.remote.lastPathComponent, sentHash: self.hash(self.local, control), revision: revision))
            return self.local
        }
    }

    /// Returns true when another save arrived during publication. A failure keeps both the snapshot and working file.
    func save(provider: RemoteProvider, context: CloudTransferContext = .init()) async throws -> Bool {
        try await run(context: context) { control in
            guard var session = try self.load() else { throw RemoteEditError.damaged }
            guard let publisher = provider as? RemoteEditPublishing, let revision = session.revision else { throw RemoteEditError.copyOnly }
            let currentHash = try self.hash(self.local, control)
            if session.uploadID == nil {
                guard currentHash != session.sentHash else { return false }
                let id = UUID(), snapshot = self.snapshot(id)
                try self.create(snapshot.deletingLastPathComponent())
                try FileManager.default.copyItem(at: self.local, to: snapshot)
                let snapshotHash = try self.hash(snapshot, control)
                guard snapshotHash == currentHash else { throw RemoteEditError.changed }
                try self.sync(snapshot)
                try self.syncDirectory(snapshot.deletingLastPathComponent())
                try self.syncDirectory(snapshot.deletingLastPathComponent().deletingLastPathComponent())
                session.uploadID = id; session.uploadHash = snapshotHash
                try self.save(session)
            }
            guard let id = session.uploadID, let expected = session.uploadHash, try self.hash(self.snapshot(id), control) == expected else {
                throw RemoteEditError.damaged
            }
            try control.checkpoint()
            session.revision = try publisher.publishEdit(self.snapshot(id), to: self.remote, expectedRevision: revision)
            session.sentHash = expected; session.uploadID = nil; session.uploadHash = nil
            try self.save(session)
            try? FileManager.default.removeItem(at: self.snapshot(id).deletingLastPathComponent())
            return try self.hash(self.local, control) != session.sentHash
        }
    }

    private func snapshot(_ id: UUID) -> URL {
        folder.appendingPathComponent("Uploads/" + id.uuidString).appendingPathComponent(local.lastPathComponent)
    }
    private func hash(_ url: URL, _ control: JobControl) throws -> String {
        try FileChecksums.digest(url, cancellation: control.asDiskCancellation())
    }
    private func create(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func load() throws -> RemoteEditSession? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        guard let session = try? JSONDecoder().decode(RemoteEditSession.self, from: Data(contentsOf: recordURL)),
            session.version == 1, session.remote == remote, session.name == local.lastPathComponent
        else { throw RemoteEditError.damaged }
        return session
    }
    private func save(_ session: RemoteEditSession) throws {
        try create(folder)
        try JSONEncoder().encode(session).write(to: recordURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        try sync(recordURL)
        try syncDirectory(folder)
    }
    private func syncDirectory(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
    private func sync(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func run<T>(context: CloudTransferContext, _ body: @escaping (JobControl) throws -> T) async throws -> T {
        let control = JobControl()
        return try await withTaskCancellationHandler {
            try await context.checkpoint()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let progressLock = NSLock()
                        var bytes: Int64 = 0
                        let transfer = control.asTransferControl(
                            onBytes: { delta in
                                progressLock.withLock {
                                    bytes += max(0, delta); context.progress(bytes, max(bytes, 1))
                                }
                            }, onStatus: context.status)
                        let result = try Shell.withTransferControl(transfer) {
                            try control.checkpoint(); return try body(control)
                        }
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }
}
