import CryptoKit
import Foundation
import PorpoiseCore

/// Copy-only opens never publish to the server. Launched files are read-only and independent of preview caches.
/// A changed/unlocked copy is retained; only old, unchanged, read-only copies may be swept.
final class RemoteOpenCopyStore: @unchecked Sendable {
    private struct Record: Codable {
        var version = 1
        var name: String
        var fingerprint: JobJournal.Fingerprint
        var hash: String
        var created: Date
    }
    let folder: URL
    private let remote: URL
    private let queue = DispatchQueue(label: "porpoise.remote-copy", qos: .userInitiated)
    private var previous: URL?
    private static let launchedLock = NSLock()
    private static var launched: Set<URL> = []
    private static func canonical(_ remote: URL) -> URL? {
        guard var parts = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return nil }
        parts.password = nil; parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        // An omitted SSH port may come from ~/.ssh/config. It must not alias an explicit :22 connection.
        return parts.url
    }
    static func identity(_ remote: URL) -> String {
        SHA256.hash(data: Data((canonical(remote)?.absoluteString ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(remote: URL, root: URL) {
        self.remote = Self.canonical(remote) ?? URL(fileURLWithPath: "/")
        folder = root.appendingPathComponent(Self.identity(remote), isDirectory: true)
    }
    func open(provider: RemoteProvider, context: CloudTransferContext = .init()) async throws -> URL {
        try await prepare(context: context) { incoming in
            guard !self.remote.isFileURL else { throw CloudContentError.unsupported }
            try RemoteFS.checkName(self.remote.lastPathComponent)
            return try provider.download(self.remote, into: incoming)
        }
    }
    func copy(_ source: URL, context: CloudTransferContext = .init()) async throws -> URL {
        try await prepare(context: context) { incoming in
            let target = incoming.appendingPathComponent(try RemoteFS.localName(source.lastPathComponent))
            try cloudClone(source, to: target); return target
        }
    }
    private func prepare(context: CloudTransferContext, load: @escaping (URL) throws -> URL) async throws -> URL {
        try await run(context: context) { control in
            try self.sweep(control: control)
            let incoming = self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var published = false
            defer { if !published { try? FileManager.default.removeItem(at: incoming) } }
            let content = incoming.appendingPathComponent("Content", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let local = try load(content)
            try control.checkpoint()
            let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard local.deletingLastPathComponent().standardizedFileURL == content.standardizedFileURL,
                RemoteParsing.isSafeName(local.lastPathComponent), values.isRegularFile == true, values.isSymbolicLink != true
            else { throw CloudContentError.changed }
            let hash = try FileChecksums.digest(local, cancellation: control.asDiskCancellation())
            if let previous = self.previous, Self.isReadOnly(previous),
                (try? FileChecksums.digest(previous, cancellation: control.asDiskCancellation())) == hash
            {
                return previous
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: local.path)
            guard let fingerprint = JobJournal.Fingerprint(local) else { throw CloudContentError.changed }
            let record = Record(name: local.lastPathComponent, fingerprint: fingerprint, hash: hash, created: Date())
            let metadata = incoming.appendingPathComponent(".porpoise-copy.json")
            try JSONEncoder().encode(record).write(to: metadata, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            Self.launchedLock.withLock { _ = Self.launched.insert(local) }
            self.previous = local; published = true
            return local
        }
    }
    /// Disconnect must not erase an unlocked/edited copy. Hashing runs off the main actor, as with cloud edits.
    static func checkUnchangedCopies(in root: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fm = FileManager.default
                    guard fm.fileExists(atPath: root.path) else { continuation.resume(); return }
                    for identity in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                        guard (try identity.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                            throw CloudConnectionError.unsentEdits
                        }
                        for candidate in try fm.contentsOfDirectory(at: identity, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                            guard UUID(uuidString: candidate.lastPathComponent) != nil,
                                (try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                                let data = try? Data(contentsOf: candidate.appendingPathComponent(".porpoise-copy.json")),
                                let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
                                RemoteParsing.isSafeName(record.name)
                            else { throw CloudConnectionError.unsentEdits }
                            let content = candidate.appendingPathComponent("Content")
                            let local = content.appendingPathComponent(record.name)
                            guard (try content.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                                (try local.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                                let permissions = try fm.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber,
                                permissions.intValue & 0o222 == 0,
                                try FileChecksums.digest(local) == record.hash
                            else { throw CloudConnectionError.unsentEdits }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func isReadOnly(_ local: URL) -> Bool {
        guard let values = try? local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let permissions = try? FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.intValue & 0o222 == 0
    }
    /// Never visits legacy edit sessions, unknown directories, symlinks, current-process copies or changed bytes.
    func sweep(now: Date = Date(), control: JobControl = JobControl()) throws {
        try Self.sweepFolder(folder, now: now, control: control)
    }
    static func sweepRoot(_ root: URL, now: Date = Date(), control: JobControl = JobControl()) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for identity in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            try control.checkpoint()
            guard identity.lastPathComponent.count == 64, identity.lastPathComponent.allSatisfy({ $0.isHexDigit }),
                (try? identity.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
            else { continue }
            try sweepFolder(identity, now: now, control: control)
            // rmdir removes only an empty directory, even if another open starts during the sweep.
            _ = identity.withUnsafeFileSystemRepresentation { path in path.map { Darwin.rmdir($0) } ?? -1 }
        }
    }
    private static func sweepFolder(_ folder: URL, now: Date, control: JobControl) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for candidate in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            try control.checkpoint()
            guard UUID(uuidString: candidate.lastPathComponent) != nil,
                (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                let data = try? Data(contentsOf: candidate.appendingPathComponent(".porpoise-copy.json")),
                let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
                RemoteParsing.isSafeName(record.name), now.timeIntervalSince(record.created) > 7 * 86400
            else { continue }
            let content = candidate.appendingPathComponent("Content", isDirectory: true)
            let local = content.appendingPathComponent(record.name)
            guard (try? content.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                !Self.launchedLock.withLock({ Self.launched.contains(local) }), Self.isReadOnly(local),
                JobJournal.Fingerprint(local) == record.fingerprint,
                (try? FileChecksums.digest(local, cancellation: control.asDiskCancellation())) == record.hash,
                Set(try FileManager.default.contentsOfDirectory(atPath: candidate.path)) == ["Content", ".porpoise-copy.json"],
                try FileManager.default.contentsOfDirectory(atPath: content.path) == [record.name]
            else { continue }
            try FileManager.default.removeItem(at: candidate)
        }
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
