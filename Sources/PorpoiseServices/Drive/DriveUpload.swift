import CryptoKit
import Foundation
import PorpoiseCore

extension DriveClient {
    public func upload(
        _ local: URL, parentID: String, name: String? = nil, operationID: UUID = UUID(), context: DriveTransferContext = .init(),
        replacingID: String? = nil, expectedVersion: String? = nil
    ) async throws -> DriveFile {
        if isOffline { throw DriveError.offline }
        let name = name ?? local.lastPathComponent
        try RemoteFS.checkName(name)
        if replacingID == nil { _ = try await writableParent(parentID) } else { try await tokens.requireWriteScope() }
        guard let fingerprint = JobJournal.Fingerprint(local),
            try local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { throw DriveMutationError.sourceChanged }
        try mutationJournal.claim(operationID)
        defer { mutationJournal.release(operationID) }
        var record =
            try mutationJournal.load(operationID)
            ?? DriveMutationRecord(
                operationID: operationID, accountID: accountID, kind: replacingID == nil ? "upload" : "replace", sourceID: replacingID,
                parentID: parentID, name: name)
        guard record.accountID == accountID, record.kind == (replacingID == nil ? "upload" : "replace"), record.sourceID == replacingID,
            record.parentID == parentID, record.name == name,
            record.localSource == nil || record.localSource == local,
            record.fingerprint == nil || record.fingerprint == fingerprint
        else { throw DriveMutationError.sourceChanged }
        if let result = record.result { return result }
        if let replacingID {
            let existing = try await file(replacingID)
            guard !existing.isGoogleDocument, !existing.isFolder, existing.operations.canWrite else { throw DriveError.permissionDenied }
            if record.phase == .prepared {
                guard expectedVersion == nil || existing.version == expectedVersion else { throw DriveMutationError.conflict }
                guard let revision = existing.headRevisionId, DriveLink.isValidID(revision) else { throw DriveMutationError.conflict }
                // Pin the old bytes before creating a new revision. Pin failure leaves the old file intact.
                var pin = URLComponents(
                    url: baseURL.appendingPathComponent("files/\(replacingID)/revisions/\(revision)"), resolvingAgainstBaseURL: false)!
                pin.queryItems = [URLQueryItem(name: "fields", value: "id,keepForever")]
                let (data, _) = try await mutationResponse(
                    pin.url!, method: "PATCH", body: JSONSerialization.data(withJSONObject: ["keepForever": true]),
                    headers: ["Content-Type": "application/json"])
                struct Revision: Decodable { let keepForever: Bool }
                guard try decode(Revision.self, data).keepForever else { throw DriveMutationError.conflict }
                let protected = try await file(replacingID)
                guard protected.headRevisionId == revision, protected.md5Checksum == existing.md5Checksum else { throw DriveMutationError.conflict }
                record.itemID = replacingID; record.revision = protected.version; record.previousRevisionID = revision
            } else if existing.appProperties?["porpoiseOperation"] != operationID.uuidString && existing.version != record.revision {
                throw DriveMutationError.conflict
            }
        }
        if record.phase != .prepared, let recovered = try await reconcile(record),
            replacingID == nil || recovered.appProperties?["porpoiseOperation"] == operationID.uuidString
        {
            guard recovered.size.flatMap(Int64.init) == fingerprint.size, recovered.md5Checksum == (try Self.md5(local)) else {
                throw DriveMutationError.sourceChanged
            }
            record.result = recovered; record.phase = .committed; try mutationJournal.save(record)
            invalidateMutation(parents: [parentID]); return recovered
        }
        record.localSource = local; record.fingerprint = fingerprint
        try mutationJournal.save(record)
        let total = fingerprint.size
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        var session: URL?
        if record.hasSession, let secret = try await tokens.session(operationID) { session = try validatedSession(secret) }
        if let url = session {
            do {
                let result = try await mutationResponse(
                    url, method: "PUT", body: Data(), headers: ["Content-Range": "bytes */\(total)"], context: context)
                if result.1.statusCode != 308 { return try await finishUpload(result.0, record: &record, local: local, context: context) }
                record.offset = try confirmedOffset(result.1, total: total)
                try mutationJournal.save(record)
            } catch DriveError.notFound {
                session = nil; record.offset = 0; record.hasSession = false
                try mutationJournal.save(record); try await tokens.removeSession(operationID)
            }
        }
        if session == nil {
            // Persist a stable ID before initiation so an expired/lost session cannot create a second object.
            if record.itemID == nil {
                struct IDs: Decodable { let ids: [String] }
                var idsURL = URLComponents(url: baseURL.appendingPathComponent("files/generateIds"), resolvingAgainstBaseURL: false)!
                idsURL.queryItems = [URLQueryItem(name: "count", value: "1")]
                let (data, _) = try await mutationResponse(idsURL.url!)
                // URL construction below deliberately avoids encoding a query into the opaque path.
                record.itemID = try decode(IDs.self, data).ids.first
                guard let id = record.itemID, DriveLink.isValidID(id) else { throw DriveError.invalidResponse }
            }
            record.phase = .requesting; try mutationJournal.save(record)
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.path = "/upload" + components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash + "/files"
            if let replacingID { components.path += "/" + replacingID }
            components.queryItems = [
                URLQueryItem(name: "uploadType", value: "resumable"), URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: Self.fields),
            ]
            var metadata: [String: Any] = ["appProperties": ["porpoiseOperation": operationID.uuidString]]
            if replacingID == nil { metadata["id"] = record.itemID!; metadata["name"] = name; metadata["parents"] = [parentID] }
            if let replacingID {
                let fresh = try await file(replacingID)
                guard fresh.version == record.revision else { throw DriveMutationError.conflict }
            }
            let (_, response) = try await mutationResponse(
                components.url!, method: replacingID == nil ? "POST" : "PATCH", body: JSONSerialization.data(withJSONObject: metadata),
                headers: [
                    "Content-Type": "application/json", "X-Upload-Content-Type": "application/octet-stream", "X-Upload-Content-Length": String(total),
                ], context: context)
            guard let location = response.value(forHTTPHeaderField: "Location") else { throw DriveError.invalidResponse }
            session = try validatedSession(location)
            try await tokens.saveSession(location, id: operationID)
            record.hasSession = true; record.phase = .transferring; record.offset = 0; try mutationJournal.save(record)
        }
        guard let session else { throw DriveMutationError.invalidSession }
        context.progress(record.offset, total)
        repeat {
            try await context.checkpoint()
            guard JobJournal.Fingerprint(local) == fingerprint else { throw DriveMutationError.sourceChanged }
            try input.seek(toOffset: UInt64(record.offset))
            let data = try input.read(upToCount: Int(min(256 * 1024, total - record.offset))) ?? Data()
            let range = total == 0 ? "bytes */0" : "bytes \(record.offset)-\(record.offset + Int64(data.count) - 1)/\(total)"
            let (body, response) = try await mutationResponse(
                session, method: "PUT", body: data, headers: ["Content-Range": range, "Content-Type": "application/octet-stream"], context: context)
            if response.statusCode != 308 { return try await finishUpload(body, record: &record, local: local, context: context) }
            let offset = try confirmedOffset(response, total: total)
            guard offset > record.offset else { throw DriveError.invalidResponse }
            record.offset = offset; try mutationJournal.save(record)
            context.progress(offset, total)
        } while record.offset < total
        throw DriveError.invalidResponse
    }

    private func finishUpload(_ data: Data, record: inout DriveMutationRecord, local: URL, context: DriveTransferContext) async throws -> DriveFile {
        let result = try decode(DriveFile.self, data)
        guard result.id == record.itemID, Int64(result.size ?? "") == record.fingerprint?.size,
            JobJournal.Fingerprint(local) == record.fingerprint
        else { throw DriveMutationError.sourceChanged }
        guard let md5 = result.md5Checksum, md5 == (try Self.md5(local)) else { throw DriveError.invalidResponse }
        let fresh = try await file(result.id)
        guard fresh.version == result.version, fresh.md5Checksum == result.md5Checksum, fresh.size == result.size else {
            throw DriveMutationError.conflict
        }
        record.result = result; record.offset = record.fingerprint!.size; record.phase = .committed
        try mutationJournal.save(record)
        try await tokens.removeSession(record.operationID)
        remember([result]); invalidateMutation(parents: result.parents ?? [])
        context.progress(record.offset, record.offset)
        return result
    }

    static func md5(_ local: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: local)
        defer { try? file.close() }
        var digest = Insecure.MD5()
        while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func confirmedOffset(_ response: HTTPURLResponse, total: Int64) throws -> Int64 {
        guard let range = response.value(forHTTPHeaderField: "Range") else { return 0 }
        guard range.hasPrefix("bytes=0-"), let end = Int64(range.dropFirst(8)), end >= 0, end < total else { throw DriveError.invalidResponse }
        return end + 1
    }

    private func validatedSession(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.user == nil, url.password == nil, url.fragment == nil else { throw DriveMutationError.invalidSession }
        let google = url.scheme == "https" && url.host == "www.googleapis.com" && url.path.hasPrefix("/upload/drive/")
        let fixture =
            baseURL.scheme == "http" && baseURL.host == "127.0.0.1" && url.scheme == "http" && url.host == baseURL.host && url.port == baseURL.port
        guard google || fixture else { throw DriveMutationError.invalidSession }
        return url
    }
}

private extension String { var withLeadingSlash: String { "/" + self } }
