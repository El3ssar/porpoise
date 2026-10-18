import Foundation
import PorpoiseCore

extension BoxClient {
    /// A name Box accepts as one item: no slashes, no control characters, no edge spaces, not "." or "..", at most 255
    /// characters. https://developer.box.com/reference/post-folders/ (name)
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), name.count <= 255,
            !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }), name.trimmingCharacters(in: .whitespaces) == name
        else { throw BoxError.invalidLocation }
    }
    public func createFolder(name: String, parentID: String = BoxItem.rootID, operationID: UUID = UUID()) async throws -> BoxItem {
        try Self.validateName(name)
        let parentID = parentID.isEmpty ? BoxItem.rootID : parentID
        return try await mutate("create", item: parentID, name: name, operationID: operationID, expect: .folder) {
            try self.request(
                self.api("folders", query: [.init(name: "fields", value: Self.fields)]), method: "POST",
                json: ["name": name, "parent": ["id": parentID]])
        }
    }
    /// Moves (and renames), conditional on the etag read (If-Match). An existing name is refused, never replaced.
    public func move(_ item: BoxItem, to parentID: String, named name: String? = nil, operationID: UUID = UUID()) async throws -> BoxItem {
        let name = name ?? item.name
        try Self.validateName(name)
        let parent = parentID.isEmpty ? BoxItem.rootID : parentID
        guard !item.isRoot, item.id != parent, let tag = item.etag else { throw BoxError.invalidLocation }
        return try await mutate("move", item: item.id, name: parent + "/" + name, revision: tag, operationID: operationID, expect: item.kind) {
            try self.request(
                self.api(self.itemPath(item.id, item.kind), query: [.init(name: "fields", value: Self.fields)]), method: "PUT",
                json: ["name": name, "parent": ["id": parent]], headers: ["If-Match": tag])
        }
    }
    public func rename(_ item: BoxItem, to name: String, operationID: UUID = UUID()) async throws -> BoxItem {
        guard let parent = item.parentID else { throw BoxError.invalidLocation }
        return try await move(item, to: parent, named: name, operationID: operationID)
    }
    /// Box copies in the request itself (a large folder's answer can take a while). A lost answer stays uncertain.
    /// https://developer.box.com/reference/post-files-id-copy/
    public func copy(_ item: BoxItem, to parentID: String, named name: String? = nil, operationID: UUID = UUID()) async throws -> BoxItem {
        let name = name ?? item.name
        try Self.validateName(name)
        let parent = parentID.isEmpty ? BoxItem.rootID : parentID
        guard !item.isRoot, item.kind != .webLink else { throw BoxError.invalidLocation }
        return try await mutate(
            "copy", item: item.id, name: parent + "/" + name, revision: item.revision, operationID: operationID, expect: item.kind
        ) {
            try self.request(
                self.api(self.itemPath(item.id, item.kind) + "/copy", query: [.init(name: "fields", value: Self.fields)]), method: "POST",
                json: ["name": name, "parent": ["id": parent]])
        }
    }
    /// Moves `item` to Box's trash, conditional on the etag read (If-Match); `restore` brings it back.
    /// https://developer.box.com/reference/delete-files-id/
    public func delete(_ item: BoxItem, operationID: UUID = UUID()) async throws -> BoxItem {
        guard !item.isRoot, let tag = item.etag else { throw BoxError.invalidResponse }
        let removed = try await mutate("delete", item: item.id, revision: tag, operationID: operationID, expect: item.kind) {
            try self.request(
                self.api(self.itemPath(item.id, item.kind), query: item.isFolder ? [.init(name: "recursive", value: "true")] : []),
                method: "DELETE", headers: ["If-Match": tag])
        }
        noteTrashed(item)
        var gone = [item.id], ids: [String] = []
        let children = boxChildren(metadataCache.files)
        while let id = gone.popLast() { ids.append(id); gone += children[id] ?? [] }
        metadataCache.apply([], removed: ids, belongs: { _, _ in false })
        emit(CloudChangeBatch(removed: ids)); metadataCache.invalidate(); onFreshness?()
        return removed
    }
    /// Brings a trashed item back where it was. Box refuses (409) when its name is taken there meanwhile: nothing is
    /// replaced. https://developer.box.com/reference/post-files-id/
    public func restore(_ id: String, kind: BoxItem.Kind? = nil, operationID: UUID = UUID()) async throws -> BoxItem {
        guard let kind = kind ?? self.kind(of: id), id != BoxItem.rootID else { throw BoxError.unsupportedUndo }
        return try await mutate("restore", item: id, operationID: operationID, expect: kind) {
            try self.request(
                self.api(self.itemPath(id, kind), query: [.init(name: "fields", value: Self.fields)]), method: "POST", json: [String: Any]())
        }
    }
    /// One journaled, non-idempotent request. A lost answer stays uncertain: there's no operation key to prove the
    /// item that may now exist is ours.
    private func mutate(
        _ kind: String, item: String, name: String? = nil, revision: String? = nil, operationID: UUID, expect: BoxItem.Kind,
        request: () throws -> URLRequest
    ) async throws -> BoxItem {
        try journal.claim(operationID); defer { journal.release(operationID) }
        if let previous = try journal.load(operationID) {
            guard previous.kind == kind, previous.path == item, previous.destination == name, previous.revision == revision else {
                throw BoxError.sourceChanged
            }
            if previous.phase == "done", let result = previous.result { return result }
            if previous.phase == "conflict" { throw BoxError.conflict }
            throw BoxError.uncertain
        }
        var record = BoxOperation(operationID: operationID, kind: kind, path: item)
        record.destination = name; record.revision = revision; record.phase = "submitted"; try journal.save(record)
        do {
            let (data, response) = try await send(try request(), idempotent: false)
            let result: BoxItem
            if kind == "delete" {
                guard response.statusCode == 204 else { throw BoxError.invalidResponse }
                result = metadataCache.file(item) ?? BoxItem(id: item, name: "", kind: expect)
            } else {
                result = try JSONDecoder().decode(BoxItem.self, from: data)
                guard result.kind == expect, ["move", "restore"].contains(kind) ? result.id == item : true, !result.isDeleted else {
                    throw BoxError.invalidResponse
                }
            }
            record.result = result; record.phase = "done"; try journal.save(record)
            if kind != "delete" { metadataCache.remember([result]) }
            metadataCache.invalidate(); onFreshness?(); return result
        } catch {
            record.phase = (error as? BoxError) == .conflict ? "conflict" : "uncertain"
            try journal.save(record); throw error
        }
    }
}
