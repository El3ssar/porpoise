import Foundation
import PorpoiseCore

extension OneDriveClient {
    /// A name OneDrive accepts as one item: no path separators, no reserved names. The service refuses the rest itself.
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
            !name.contains(":"), name.trimmingCharacters(in: .whitespaces) == name
        else { throw OneDriveError.invalidLocation }
    }
    public func createFolder(name: String, parentID: String = "", operationID: UUID = UUID()) async throws -> OneDriveItem {
        try Self.validateName(name)
        return try await mutate("create", item: parentID, name: name, operationID: operationID) {
            try self.request(
                self.graph(self.itemPath(parentID) + "/children"), method: "POST",
                json: ["name": name, "folder": [String: Any](), "@microsoft.graph.conflictBehavior": "fail"])
        }
    }
    /// Moves (and renames) within this drive. An existing name is refused, never replaced.
    public func move(_ item: OneDriveItem, to parentID: String, named name: String? = nil, operationID: UUID = UUID()) async throws
        -> OneDriveItem
    {
        let name = name ?? item.name
        try Self.validateName(name)
        guard !item.isRoot, item.id != parentID, let parent = parentID.isEmpty ? rootID : parentID else { throw OneDriveError.invalidLocation }
        let body: [String: Any] = ["name": name, "parentReference": ["id": parent]]
        return try await mutate("move", item: item.id, name: parent + "/" + name, revision: item.revision, operationID: operationID) {
            try self.request(
                self.graph(self.itemPath(item.id), query: [.init(name: "@microsoft.graph.conflictBehavior", value: "fail")]), method: "PATCH",
                json: body)
        }
    }
    public func rename(_ item: OneDriveItem, to name: String, operationID: UUID = UUID()) async throws -> OneDriveItem {
        guard let parent = item.parentID else { throw OneDriveError.invalidLocation }
        return try await move(item, to: parent, named: name, operationID: operationID)
    }
    /// Graph copies in the background: the request answers 202 with a monitor URL, polled (without the bearer) until
    /// the copy has its item. The monitor is journaled, so an interrupted copy is followed again, never started twice.
    /// https://learn.microsoft.com/graph/long-running-actions-overview
    public func copy(_ item: OneDriveItem, to parentID: String, named name: String? = nil, operationID: UUID = UUID()) async throws
        -> OneDriveItem
    {
        let name = name ?? item.name
        try Self.validateName(name)
        guard let parent = parentID.isEmpty ? rootID : parentID else { throw OneDriveError.invalidLocation }
        let destination = parent + "/" + name
        try journal.claim(operationID); defer { journal.release(operationID) }
        var record = try journal.load(operationID) ?? OneDriveOperation(operationID: operationID, kind: "copy", path: item.id)
        guard record.kind == "copy", record.path == item.id, record.destination == nil || record.destination == destination else {
            throw OneDriveError.sourceChanged
        }
        if record.phase == "done", let result = record.result { return result }
        if record.phase == "conflict" { throw OneDriveError.conflict }
        if record.phase == "submitted" || record.phase == "uncertain" { throw OneDriveError.uncertain }
        if record.monitor == nil {
            record.destination = destination; record.revision = item.revision; record.phase = "submitted"; try journal.save(record)
            do {
                let request = try request(
                    graph(itemPath(item.id) + "/copy", query: [.init(name: "@microsoft.graph.conflictBehavior", value: "fail")]), method: "POST",
                    json: ["parentReference": ["driveId": driveID, "id": parent], "name": name])
                let (_, response) = try await send(request, idempotent: false)
                guard response.statusCode == 202, let raw = response.value(forHTTPHeaderField: "Location"), let monitor = URL(string: raw),
                    monitor.scheme == "https" || configuration.isGraph(monitor)
                else { throw OneDriveError.invalidResponse }
                record.monitor = monitor; record.phase = "copying"; try journal.save(record)
            } catch {
                record.phase = (error as? OneDriveError) == .conflict ? "conflict" : "uncertain"; try journal.save(record); throw error
            }
        }
        struct Status: Decodable {
            struct Failure: Decodable { var code: String? }
            var status: String; var resourceId: String?; var error: Failure?
        }
        var delay: UInt64 = 50_000_000
        while true {
            try Task.checkCancellation()
            let (data, response) = try await http.response(URLRequest(url: record.monitor!))
            try Self.check(data, response)
            let status = try JSONDecoder().decode(Status.self, from: data)
            switch status.status {
            case "completed":
                guard let id = status.resourceId else { throw OneDriveError.invalidResponse }
                let result = try await metadata(id)
                record.result = result; record.phase = "done"; try journal.save(record)
                metadataCache.invalidate(); onFreshness?(); return result
            case "failed":
                record.phase = status.error?.code == "nameAlreadyExists" ? "conflict" : "uncertain"; try journal.save(record)
                throw record.phase == "conflict" ? OneDriveError.conflict : OneDriveError.api(500, status.error?.code ?? "")
            default:
                try await Task.sleep(nanoseconds: delay); delay = min(delay * 2, 2_000_000_000)
            }
        }
    }
    /// Deletion is conditional on the revision read (If-Match). OneDrive keeps it in its recycle bin, but there is no
    /// Undo here: a folder needs explicit confirmation.
    public func delete(_ item: OneDriveItem, confirmedWithoutUndo: Bool = false, operationID: UUID = UUID()) async throws -> OneDriveItem {
        guard !item.isFolder || confirmedWithoutUndo else { throw OneDriveError.unsupportedUndo }
        guard !item.isRoot, let tag = item.eTag else { throw OneDriveError.invalidResponse }
        let removed = try await mutate("delete", item: item.id, revision: tag, operationID: operationID) {
            try self.request(self.graph(self.itemPath(item.id)), method: "DELETE", headers: ["If-Match": tag])
        }
        var gone = [item.id], ids: [String] = []
        let children = oneDriveChildren(metadataCache.files)
        while let id = gone.popLast() { ids.append(id); gone += children[id] ?? [] }
        metadataCache.apply([], removed: ids, belongs: { _, _ in false })
        emit(CloudChangeBatch(removed: ids)); metadataCache.invalidate(); onFreshness?()
        return removed
    }
    /// One journaled, non-idempotent request. A lost answer stays uncertain: there's no operation key to prove the
    /// item that may now exist is ours.
    private func mutate(
        _ kind: String, item: String, name: String? = nil, revision: String? = nil, operationID: UUID,
        request: () throws -> URLRequest
    ) async throws -> OneDriveItem {
        try journal.claim(operationID); defer { journal.release(operationID) }
        if let previous = try journal.load(operationID) {
            guard previous.kind == kind, previous.path == item, previous.destination == name, previous.revision == revision else {
                throw OneDriveError.sourceChanged
            }
            if previous.phase == "done", let result = previous.result { return result }
            if previous.phase == "conflict" { throw OneDriveError.conflict }
            throw OneDriveError.uncertain
        }
        var record = OneDriveOperation(operationID: operationID, kind: kind, path: item)
        record.destination = name; record.revision = revision; record.phase = "submitted"; try journal.save(record)
        do {
            let (data, response) = try await send(try request(), idempotent: false)
            var result: OneDriveItem
            if kind == "delete" {
                guard response.statusCode == 204 else { throw OneDriveError.invalidResponse }
                result = metadataCache.file(item) ?? OneDriveItem(id: item, name: "")
            } else {
                result = try JSONDecoder().decode(OneDriveItem.self, from: data)
                if result.driveID == nil { result.driveID = driveID }
                guard kind != "create" || result.isFolder, kind != "move" || result.id == item else { throw OneDriveError.invalidResponse }
            }
            record.result = result; record.phase = "done"; try journal.save(record)
            if kind != "delete" { metadataCache.remember([result]) }
            metadataCache.invalidate(); onFreshness?(); return result
        } catch {
            record.phase = (error as? OneDriveError) == .conflict ? "conflict" : "uncertain"
            try journal.save(record); throw error
        }
    }
}
