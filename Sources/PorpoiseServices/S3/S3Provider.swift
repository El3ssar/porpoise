import Foundation
import PorpoiseCore

/// Path-based adapter: directory loading, conflicts, local publication and Activity use the shared remote engine.
public final class S3Provider: RemoteProvider, @unchecked Sendable {
    public let client: S3Client
    public init(location: S3Location) { client = S3Client(location: location) }
    public init(client: S3Client) { self.client = client }
    private func location(_ url: URL) throws -> S3Location {
        guard let location = S3Location(url: url), location.bucket == client.location.bucket,
            location.endpoint == client.location.endpoint, location.region == client.location.region,
            location.accountID == client.location.accountID
        else { throw S3Error.invalidLocation }
        return location
    }
    private func resolved(_ location: S3Location) throws -> S3Location {
        guard !location.key.isEmpty, !location.key.hasSuffix("/") else { return location }
        return try CloudAwait.run {
            if try await self.client.exists(location.key) { return location }
            let marker = try await self.client.exists(location.prefix)
            let children = try await self.client.list(prefix: location.prefix)
            if marker || !children.isEmpty {
                return location.replacingKey(location.prefix)
            }
            return location
        }
    }
    public func rootTitle(_ url: URL) -> String { client.location.bucket }
    public func list(_ folder: URL) throws -> [FileItem] {
        let location = try location(folder)
        return try CloudAwait.run {
            try await self.client.list(prefix: location.prefix).map { object in
                let suffix = String(object.key.dropFirst(location.prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                // Never turn an untrusted object key into a local path component.
                try RemoteFS.checkName(suffix)
                return FileItem(
                    url: location.replacingKey(object.key).url, name: suffix, isDirectory: object.isFolder, size: object.size,
                    modificationDate: object.modified, contentType: object.isFolder ? "public.folder" : nil, isWritable: true)
            }
        }
    }
    public func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let location = try resolved(location(remote)), name = try RemoteFS.localName(remote.lastPathComponent)
        return try RemoteFS.downloadStaged(name, into: localFolder) { staging in
            let destination = staging.appendingPathComponent(name)
            if location.key.hasSuffix("/") {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                for child in try list(location.url) { _ = try download(child.url, into: destination) }
            } else {
                let context = transferContext()
                let (partial, operation) = try CloudAwait.run {
                    let object = try await self.client.head(location.key)
                    let existing = try self.client.journal.all().first { $0.kind == "download" && $0.key == object.key && $0.revision == object.etag }
                    let operation = existing?.operationID ?? UUID()
                    return (try await self.client.download(object, operationID: operation, context: context), operation)
                }
                try FileManager.default.copyItem(at: partial, to: destination)
                if let record = try client.journal.load(operation) {
                    try CloudStagedDownload.removeOwned(partial, fingerprint: record.fingerprint)
                    try client.journal.remove(operation)
                }
            }
        }
    }
    public func upload(_ local: URL, into remoteFolder: URL) throws {
        try upload(local, folder: location(remoteFolder), ancestors: [])
    }
    private func upload(_ local: URL, folder: S3Location, ancestors: Set<String>) throws {
        try RemoteFS.checkName(local.lastPathComponent)
        let key = folder.prefix + local.lastPathComponent
        let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true {
            let real = local.resolvingSymlinksInPath().path
            guard !ancestors.contains(real) else { return }
            try makeFolder(folder.replacingKey(key + "/").url)
            var ancestors = ancestors; ancestors.insert(real)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, folder: folder.replacingKey(key + "/"), ancestors: ancestors)
            }
        } else {
            if client.location.endpoint.host?.hasSuffix(".r2.cloudflarestorage.com") == true,
                let size = JobJournal.Fingerprint(local)?.size, size > client.multipartCopyThreshold
            {
                throw RemoteError.unsupported("R2 cannot safely publish staged files above 5 GiB. The local source was kept.")
            }
            let context = transferContext()
            try CloudAwait.run {
                let existing = try self.client.journal.all().first { $0.kind == "upload" && $0.key == key && $0.localURL == local }
                try await self.client.upload(local, key: key, operationID: existing?.operationID ?? UUID(), context: context)
            }
        }
    }
    public func makeFolder(_ remote: URL) throws {
        let location = try location(remote)
        guard !location.key.isEmpty else { throw S3Error.invalidLocation }
        try CloudAwait.run {
            guard try await !self.client.exists(location.prefix), try await !self.client.exists(String(location.prefix.dropLast())) else {
                throw RemoteError.exists(remote.lastPathComponent)
            }
            _ = try await self.client.send("PUT", key: location.prefix, headers: ["If-None-Match": "*"], body: Data())
        }
    }
    public func delete(_ remote: [URL]) throws {
        for url in remote {
            let location = try resolved(location(url))
            guard !location.key.isEmpty else { throw S3Error.invalidLocation }
            try CloudAwait.run {
                if location.key.hasSuffix("/") {
                    for object in try await self.client.list(prefix: location.key, recursive: true) {
                        _ = try await self.client.send("DELETE", key: object.key)
                    }
                }
                _ = try await self.client.send("DELETE", key: location.key)
            }
        }
    }
    public func removeEmptyFolder(_ remote: URL) throws {
        let location = try location(remote)
        guard !location.key.isEmpty else { throw S3Error.invalidLocation }
        // An S3 prefix is virtual: deleting only its marker never deletes a concurrently arriving child.
        try CloudAwait.run {
            guard try await self.client.list(prefix: location.prefix, recursive: true).isEmpty else {
                throw RemoteError.failed("The S3 folder is not empty.")
            }
            _ = try await self.client.send("DELETE", key: location.prefix)
        }
    }
    public func rename(_ remote: URL, to newName: String) throws {
        try RemoteFS.checkName(newName)
        let source = try resolved(location(remote))
        let trimmed = source.key.hasSuffix("/") ? String(source.key.dropLast()) : source.key
        let parent = trimmed.lastIndex(of: "/").map { String(trimmed[...$0]) } ?? ""
        try relocate(source, to: parent + newName + (source.key.hasSuffix("/") ? "/" : ""), move: true)
    }
    public func move(_ remote: [URL], into folder: URL) throws { try relocate(remote, into: folder, move: true) }
    public func copy(_ remote: [URL], into folder: URL) throws { try relocate(remote, into: folder, move: false) }
    private func relocate(_ remote: [URL], into folder: URL, move: Bool) throws {
        let target = try location(folder)
        for url in remote {
            let source = try resolved(location(url))
            try relocate(source, to: target.prefix + url.lastPathComponent + (source.key.hasSuffix("/") ? "/" : ""), move: move)
        }
    }
    private func relocate(_ source: S3Location, to target: String, move: Bool) throws {
        guard !source.key.isEmpty, target != source.key, !target.hasPrefix(source.prefix) else { throw S3Error.invalidLocation }
        let context = transferContext()
        try CloudAwait.run {
            guard try await !self.client.exists(target), try await self.client.list(prefix: target.hasSuffix("/") ? target : target + "/").isEmpty
            else {
                throw RemoteError.exists(target)
            }
            var objects =
                source.key.hasSuffix("/") ? try await self.client.list(prefix: source.key, recursive: true) : [try await self.client.head(source.key)]
            if source.key.hasSuffix("/"), try await self.client.exists(source.key) { objects.append(try await self.client.head(source.key)) }
            // Verify every copy before deleting any source. Source conditional deletes protect concurrent changes.
            for object in objects { try await self.client.copy(object, to: target + object.key.dropFirst(source.key.count), context: context) }
            if move {
                for object in objects {
                    _ = try await self.client.send("DELETE", key: object.key, headers: ["If-Match": object.etag])
                }
            }
        }
    }
    private func transferContext() -> CloudTransferContext { Shell.transferContext() }
}

extension S3Provider: RemoteTransferPublishing, RemoteTransferTargetChecking {
    public func transferTargetExists(_ url: URL) throws -> Bool {
        let location = try location(url)
        return try CloudAwait.run {
            let exists = try await self.client.exists(location.key)
            let children = try await self.client.list(prefix: location.prefix)
            let marker = try await self.client.exists(location.prefix)
            return exists || !children.isEmpty || marker
        }
    }
    public func publishTransferFile(_ staged: URL, to target: URL, modified: Date?) throws {
        guard modified == nil else { throw RemoteError.unsupported("S3 cannot preserve modification dates. Choose Content or Size comparison.") }
        let source = try location(staged), destination = try location(target)
        try CloudAwait.run {
            let object = try await self.client.head(source.key), old = try await self.client.head(destination.key)
            try await self.client.copy(object, to: destination.key, replacing: old.etag)
            _ = try await self.client.send("DELETE", key: source.key, headers: ["If-Match": object.etag])
        }
    }
}

extension S3Provider: RemoteTransferNativeCopy {
    public func copyTransferFile(_ source: URL, to target: URL, replacing: Bool, modified: Date?) throws -> RemoteTransferNativeCopyResult? {
        guard let source = try? location(source) else { return nil }
        let target = try location(target)
        guard modified == nil else { throw RemoteError.unsupported("S3 cannot preserve modification dates. Choose Content or Size comparison.") }
        let context = transferContext()
        let object = try CloudAwait.run {
            let object = try await self.client.head(source.key)
            let revision = replacing ? try await self.client.head(target.key).etag : nil
            try await self.client.copy(object, to: target.key, replacing: revision, context: context)
            return object
        }
        return RemoteTransferNativeCopyResult {
            try CloudAwait.run { _ = try await self.client.send("DELETE", key: source.key, headers: ["If-Match": object.etag]) }
        }
    }
}
