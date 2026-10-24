import Foundation
import PorpoiseCore

extension DriveClient {
    /// Busy responses are sent again (nothing was done); a server error only for reads, as a lost mutation response
    /// goes to reconciliation.
    func mutationResponse(
        _ url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], context: DriveTransferContext? = nil,
        receive: ((Data, HTTPURLResponse) async throws -> Void)? = nil, fileBody: URL? = nil
    ) async throws -> (
        Data, HTTPURLResponse
    ) {
        if isOffline { throw DriveError.offline }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 60
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        var resourceIDs: Set<String> = []
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "files"), index + 1 < parts.count { resourceIDs.insert(parts[index + 1]) }
        if headers["Content-Type"] == "application/json", let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let parents = json["parents"] as? [String]
        {
            resourceIDs.formUnion(parents)
        }
        for query in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where query.name == "addParents" {
            resourceIDs.formUnion((query.value ?? "").split(separator: ",").map(String.init))
        }
        let keys = resourceIDs.sorted().compactMap { id -> String? in
            guard DriveLink.isValidID(id),
                let key = metadataCache.resourceKey(id),
                DriveLink.isValidID(key)
            else { return nil }
            return "\(id)/\(key)"
        }
        if !keys.isEmpty { request.setValue(keys.joined(separator: ","), forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") }
        let started = Date()
        do {
            let result = try await authorized(mutation: true).send(
                request, idempotent: method == "GET", receive: receive, before: { try await context?.checkpoint() },
                onWait: { delay in if Date().timeIntervalSince(started) + delay >= 10 { context?.status("Slowed down by Google, retrying") } },
                uploading: fileBody)
            context?.status(nil)
            return result
        } catch let error as URLError {
            if error.code != .cancelled { context?.status("Waiting for network") }
            throw error
        }
    }

    func mutationURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "supportsAllDrives", value: "true"), URLQueryItem(name: "fields", value: Self.fields)] + query
        return components.url!
    }

    private func mutationJSON(_ path: String, method: String, body: [String: Any], query: [URLQueryItem] = []) async throws -> DriveFile {
        let (data, _) = try await mutationResponse(
            mutationURL(path, query: query), method: method, body: JSONSerialization.data(withJSONObject: body),
            headers: ["Content-Type": "application/json"])
        let result = try decode(DriveFile.self, data)
        remember([result]); invalidateMutation(parents: result.parents ?? [])
        return result
    }

    func invalidateMutation(parents: [String]) {
        let provider = RemoteFS.provider(for: DriveLocation(accountID: accountID).url) as? DriveProvider
        if parents.isEmpty { provider?.invalidate() }
        let rootID = cachedFile(for: DriveLocation(accountID: accountID, collection: .folder("root")).url)?.id
        for parent in parents {
            provider?.invalidate(
                folder: DriveLocation(accountID: accountID, collection: parent == "root" || parent == rootID ? .myDrive : .folder(parent)).url)
        }
    }

    func writableParent(_ id: String) async throws -> DriveFile {
        try await tokens.requireWriteScope()
        let parent = try await file(id)
        guard parent.operations.canAddChildren else { throw DriveError.permissionDenied }
        return parent
    }

    /// Recovery never reissues an uncertain non-idempotent operation. A stable generated ID allows safe create retries.
    public func reconcile(_ record: DriveMutationRecord) async throws -> DriveFile? {
        guard record.accountID == accountID else { throw DriveError.invalidLocation }
        if let result = record.result { return result }
        if let id = record.itemID {
            do { return try await file(id, includeTrashed: true) } catch DriveError.notFound { return nil }
        }
        let q = "appProperties has { key='porpoiseOperation' and value='\(record.operationID.uuidString)' }"
        let (data, _) = try await mutationResponse(mutationURL("files", query: [URLQueryItem(name: "q", value: q)]).replacingDriveFields())
        struct Results: Decodable { var files: [DriveFile] }
        let found = try decode(Results.self, data).files
        guard found.count <= 1 else { throw DriveMutationError.conflict }
        return found.first
    }

    public func createFolder(name: String, parentID: String, operationID: UUID = UUID()) async throws -> DriveFile {
        if isOffline { throw DriveError.offline }
        return try await createOrCopy(sourceID: nil, name: name, parentID: parentID, operationID: operationID)
    }

    public func copy(_ id: String, to parentID: String, name: String? = nil, operationID: UUID = UUID()) async throws -> DriveFile {
        if isOffline { throw DriveError.offline }
        let source = try await file(id)
        guard source.operations.canCopy, !source.isFolder else { throw DriveError.permissionDenied }
        return try await createOrCopy(sourceID: id, name: name ?? source.name, parentID: parentID, operationID: operationID)
    }

    private func createOrCopy(sourceID: String?, name: String, parentID: String, operationID: UUID) async throws -> DriveFile {
        try RemoteFS.checkName(name)
        _ = try await writableParent(parentID)
        try mutationJournal.claim(operationID)
        defer { mutationJournal.release(operationID) }
        var record =
            try mutationJournal.load(operationID)
            ?? DriveMutationRecord(
                operationID: operationID, accountID: accountID, kind: sourceID == nil ? "createFolder" : "copy",
                sourceID: sourceID, parentID: parentID, name: name)
        guard record.accountID == accountID, record.sourceID == sourceID, record.parentID == parentID, record.name == name else {
            throw DriveMutationError.conflict
        }
        if record.phase != .prepared {
            if let recovered = try await reconcile(record) {
                record.result = recovered; record.phase = .done; try mutationJournal.save(record)
                invalidateMutation(parents: [parentID]); return recovered
            }
            // Query-by-marker can lag; never blindly repeat copy after a lost response.
            if sourceID != nil { throw DriveMutationError.uncertain }
        }
        if record.itemID == nil, sourceID == nil {
            var components = URLComponents(url: baseURL.appendingPathComponent("files/generateIds"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "count", value: "1"), URLQueryItem(name: "space", value: "drive")]
            struct IDs: Decodable { let ids: [String] }
            let (data, _) = try await mutationResponse(components.url!)
            guard let id = try decode(IDs.self, data).ids.first, DriveLink.isValidID(id) else { throw DriveError.invalidResponse }
            record.itemID = id
        }
        record.phase = .requesting; try mutationJournal.save(record)
        var body: [String: Any] = ["name": name, "parents": [parentID], "appProperties": ["porpoiseOperation": operationID.uuidString]]
        if sourceID == nil { body["id"] = record.itemID; body["mimeType"] = "application/vnd.google-apps.folder" }
        do {
            let result = try await mutationJSON(sourceID.map { "files/\($0)/copy" } ?? "files", method: "POST", body: body)
            record.result = result; record.itemID = result.id; record.phase = .done; try mutationJournal.save(record)
            return result
        } catch {
            if let recovered = try? await reconcile(record) {
                record.result = recovered; record.phase = .done; try mutationJournal.save(record)
                invalidateMutation(parents: [parentID]); return recovered
            }
            throw error
        }
    }

    private func patchJournaled(
        _ id: String, kind: String, body: [String: Any], query: [URLQueryItem] = [], operationID: UUID,
        allow: (DriveFile) -> Bool, satisfied: (DriveFile) -> Bool
    ) async throws -> DriveFile {
        try await tokens.requireWriteScope()
        try mutationJournal.claim(operationID)
        defer { mutationJournal.release(operationID) }
        var record =
            try mutationJournal.load(operationID)
            ?? DriveMutationRecord(
                operationID: operationID, accountID: accountID, kind: kind, sourceID: id)
        guard record.accountID == accountID, record.kind == kind, record.sourceID == id else { throw DriveMutationError.conflict }
        let current = try await file(id, includeTrashed: true)
        if record.phase != .prepared {
            if satisfied(current) {
                record.result = current; record.phase = .done; try mutationJournal.save(record)
                invalidateMutation(parents: current.parents ?? []); return current
            }
            throw DriveMutationError.uncertain
        }
        if satisfied(current) { return current }
        guard allow(current) else { throw DriveError.permissionDenied }
        record.revision = current.version; record.phase = .requesting; try mutationJournal.save(record)
        let result = try await mutationJSON("files/\(id)", method: "PATCH", body: body, query: query)
        record.result = result; record.phase = .done; try mutationJournal.save(record)
        invalidateMutation(parents: current.parents ?? [])
        return result
    }

    public func rename(_ id: String, to name: String, operationID: UUID = UUID()) async throws -> DriveFile {
        if isOffline { throw DriveError.offline }
        try RemoteFS.checkName(name)
        return try await patchJournaled(
            id, kind: "rename", body: ["name": name], operationID: operationID,
            allow: { $0.operations.canRename }, satisfied: { $0.name == name })
    }

    public func setTrashed(_ id: String, trashed: Bool, operationID: UUID = UUID()) async throws -> DriveFile {
        if isOffline { throw DriveError.offline }
        return try await patchJournaled(
            id, kind: trashed ? "trash" : "untrash", body: ["trashed": trashed], operationID: operationID,
            allow: { trashed ? $0.operations.canTrash : $0.operations.canUntrash }, satisfied: { ($0.trashed ?? false) == trashed })
    }

    public func move(_ id: String, to parentID: String, operationID: UUID = UUID(), name: String? = nil) async throws -> DriveFile {
        if isOffline { throw DriveError.offline }
        let parent = try await writableParent(parentID)
        let current = try await file(id, includeTrashed: true)
        let destinationID = parent.id
        if current.driveId != parent.driveId { return try await crossDriveMove(current, parentID: destinationID, operationID: operationID) }
        var body: [String: Any] = [:]
        if let name { try RemoteFS.checkName(name); body["name"] = name }
        return try await patchJournaled(
            id, kind: "move", body: body,
            query: [
                URLQueryItem(name: "addParents", value: destinationID),
                URLQueryItem(name: "removeParents", value: (current.parents ?? []).joined(separator: ",")),
            ], operationID: operationID, allow: { $0.operations.canMove && (name == nil || $0.operations.canRename) },
            satisfied: { $0.parents == [destinationID] && (name == nil || $0.name == name) })
    }
}

private extension URL {
    func replacingDriveFields() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems?.removeAll { $0.name == "fields" }
        components.queryItems?.append(URLQueryItem(name: "fields", value: "files(\(DriveClient.fields))"))
        return components.url!
    }
}
