import Foundation

extension DropboxClient {
    public static func childPath(name: String, parent: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
            (parent.isEmpty || parent.hasPrefix("/")), !parent.contains("\0"), !parent.contains("\\"),
            !parent.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw DropboxError.invalidLocation }
        return (parent == "/" ? "" : parent) + "/" + name
    }
    public func createFolder(name: String, parent: String = "", operationID: UUID = UUID()) async throws -> DropboxItem {
        let path = try Self.childPath(name: name, parent: parent)
        return try await mutate("files/create_folder_v2", path: path, arguments: ["path": path, "autorename": false], operationID: operationID)
    }
    public func move(_ item: DropboxItem, to path: String, operationID: UUID = UUID()) async throws -> DropboxItem {
        try validateTarget(path)
        return try await mutate(
            "files/move_v2", path: item.id, destination: path, revision: item.rev,
            arguments: ["from_path": item.id, "to_path": path, "autorename": false, "allow_shared_folder": false], operationID: operationID)
    }
    public func copy(_ item: DropboxItem, to path: String, operationID: UUID = UUID()) async throws -> DropboxItem {
        try validateTarget(path)
        return try await mutate(
            "files/copy_v2", path: item.id, destination: path, revision: item.rev,
            arguments: ["from_path": item.id, "to_path": path, "autorename": false], operationID: operationID)
    }
    public func rename(_ item: DropboxItem, to name: String, operationID: UUID = UUID()) async throws -> DropboxItem {
        guard let path = item.pathDisplay else { throw DropboxError.invalidLocation }
        let parent = String(path.prefix(upTo: path.lastIndex(of: "/") ?? path.startIndex))
        return try await move(item, to: Self.childPath(name: name, parent: parent), operationID: operationID)
    }
    /// File deletion is conditional. Folders have no revision guard or safe API Undo and need explicit confirmation.
    public func delete(_ item: DropboxItem, confirmedWithoutUndo: Bool = false, operationID: UUID = UUID()) async throws -> DropboxItem {
        guard !item.isFolder || confirmedWithoutUndo else { throw DropboxError.unsupportedUndo }
        var arguments: [String: Any] = ["path": item.id]
        if !item.isFolder { guard let rev = item.rev else { throw DropboxError.invalidResponse }; arguments["parent_rev"] = rev }
        return try await mutate("files/delete_v2", path: item.id, revision: item.rev, arguments: arguments, operationID: operationID)
    }
    /// Dropbox restore can replace the current file, with no conditional parameter. Never offer automatic Undo.
    public func restore(_ item: DropboxItem, confirmedMayReplace: Bool = false) async throws -> DropboxItem {
        guard confirmedMayReplace, !item.isFolder, let path = item.pathDisplay, let rev = item.rev else { throw DropboxError.unsupportedUndo }
        let result: DropboxItem = try await rpc("files/restore", ["path": path, "rev": rev])
        metadataCache.remember([result]); metadataCache.invalidate(); return result
    }
    func validateTarget(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"), !path.contains("\\"),
            !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else {
            throw DropboxError.invalidLocation
        }
    }
    private func mutate(
        _ route: String, path: String, destination: String? = nil, revision: String? = nil,
        arguments: [String: Any], operationID: UUID
    ) async throws -> DropboxItem {
        try journal.claim(operationID); defer { journal.release(operationID) }
        if let previous = try journal.load(operationID) {
            guard previous.kind == route, previous.path == path, previous.destination == destination, previous.revision == revision else {
                throw DropboxError.sourceChanged
            }
            if previous.phase == "done", let result = previous.result { return result }
            if previous.phase == "conflict" { throw DropboxError.conflict }
            // No server operation key: a retry cannot prove ownership of an indistinguishable new item.
            throw DropboxError.uncertain
        }
        var record = DropboxOperation(operationID: operationID, kind: route, path: path)
        record.destination = destination; record.revision = revision; record.phase = "submitted"; try journal.save(record)
        do {
            struct Result: Decodable { var metadata: DropboxItem }
            let result: Result = try await rpc(route, arguments)
            let target = destination ?? path
            guard (route != "files/create_folder_v2" || result.metadata.isFolder),
                (route != "files/move_v2" && route != "files/delete_v2" || result.metadata.id == path),
                (route == "files/delete_v2" || result.metadata.pathLower == target.lowercased())
            else { throw DropboxError.invalidResponse }
            record.result = result.metadata; record.phase = "done"; try journal.save(record)
            if route == "files/delete_v2" {
                let prefix = result.metadata.pathLower
                let removed = metadataCache.files.filter {
                    $0.id == result.metadata.id || (prefix != nil && $0.pathLower?.hasPrefix(prefix! + "/") == true)
                }.map(\.id)
                metadataCache.apply([], removed: removed, belongs: { _, _ in false })
                emit(CloudChangeBatch(removed: removed))
            } else {
                metadataCache.remember([result.metadata])
            }
            metadataCache.invalidate(); onFreshness?(); return result.metadata
        } catch {
            record.phase = (error as? DropboxError) == .conflict ? "conflict" : "uncertain"
            try journal.save(record); throw error
        }
    }
}
