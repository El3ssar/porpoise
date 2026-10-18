#if PORPOISE_TEST_HOOKS
import Foundation
import PorpoiseCore

/// Live check of edit-in-place save-back, run by the debug bridge against a signed-in account. Everything happens
/// in a new "Porpoise Probe" folder in My Drive, which is moved to the trash at the end. The report holds outcomes
/// only: no tokens, file IDs or response bodies.
public struct DriveSaveBackProbe {
    public struct Report: Codable, Sendable {
        public var steps: [String: String] = [:]
        public var passed: Bool = false
    }
    let client: DriveClient
    public init(client: DriveClient) { self.client = client }

    public func run() async -> Report {
        var report = Report()
        var folder: DriveFile?
        func step(_ name: String, _ outcome: String) { report.steps[name] = outcome }
        do {
            folder = try await client.createFolder(name: "Porpoise Probe", parentID: "root")
            let parent = try folder.map(\.id) ?? { throw DriveError.invalidResponse }()
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-probe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            // Create: a new plain-text file with one revision.
            let source = scratch.appendingPathComponent("Probe.txt")
            try Data("first version\n".utf8).write(to: source)
            let created = try await client.upload(source, parentID: parent)
            step("create", try await revisions(created.id).count == 1 ? "ok" : "unexpected revisions")

            // Conditional semantics: a stale If-Match must be refused and leave the bytes alone.
            let (_, head) = try await client.mutationResponse(fileURL(created.id))
            step("etag", head.value(forHTTPHeaderField: "ETag")?.isEmpty == false ? "returned" : "missing")
            step("staleIfMatch", await status(of: { try await mediaPatch(created, Data("stale".utf8), ifMatch: "\"porpoise-stale\"") }))
            step("staleBytesKept", try await bytes(created.id) == Data("first version\n".utf8) ? "ok" : "overwritten")
            // The v2 endpoint keeps resource etags; check whether it refuses a stale one and takes the current one.
            _ = try await client.upload(source, parentID: parent, replacingID: created.id)
            let v2 = try await v2Metadata(created.id)
            step("v2etag", v2.etag?.isEmpty == false ? "returned" : "missing")
            step("v2staleIfMatch", await status(of: { try await v2Put(created.id, Data("stale".utf8), ifMatch: "\"porpoise-stale\"") }))
            step("v2staleBytesKept", try await bytes(created.id) == Data("first version\n".utf8) ? "ok" : "overwritten")
            if let etag = v2.etag {
                step("v2matchIfMatch", await status(of: { try await v2Put(created.id, Data("matched\n".utf8), ifMatch: etag) }))
                step("v2matchBytes", try await bytes(created.id) == Data("matched\n".utf8) ? "ok" : "mismatch")
                step("v2oldEtagAfterChange", await status(of: { try await v2Put(created.id, Data("late".utf8), ifMatch: etag) }))
                step("v2etagChanges", try await v2Metadata(created.id).etag != etag ? "ok" : "same")
            }
            guard report.steps["v2staleIfMatch"] == "412" else { throw ProbeStop() }

            // Edit: another app saves atomically (new inode via rename), then the save goes back as a new revision.
            let store = client.edits
            let before = try await revisions(created.id).count
            let session = try await store.openSession(try await client.file(created.id))
            let edited = Data("edited on the Mac\n".utf8)
            try atomicSave(edited, to: session.localURL)
            let saved = try await store.saveSession(session.id)
            let afterEdit = try await revisions(created.id)
            step("edit", saved.state == .saved && saved.file.id == created.id ? "ok" : "state \(saved.state)")
            step("editBytes", try await bytes(created.id) == edited ? "ok" : "mismatch")
            step("editRevisions", afterEdit.count == before + 1 ? "ok" : "\(before) to \(afterEdit.count)")
            step("editHeadRevision", afterEdit.last?.md5Checksum == saved.file.md5Checksum ? "ok" : "mismatch")

            // Conflict: Drive changes after opening; the Mac save must not overwrite it, and Keep Both keeps both.
            let second = try await store.openSession(try await client.file(created.id))
            let remote = Data("changed in Drive meanwhile\n".utf8)
            _ = try await mediaPatch(try await client.file(created.id), remote, ifMatch: nil)
            try atomicSave(Data("conflicting Mac edit\n".utf8), to: second.localURL)
            do {
                _ = try await store.saveSession(second.id)
                step("conflict", "not detected")
            } catch {
                let state = await store.session(second.id)?.state
                step("conflict", store.engine.conflict(error) && state == .conflict ? "ok" : "error \(type(of: error))")
            }
            step("conflictRemoteKept", try await bytes(created.id) == remote ? "ok" : "overwritten")
            let kept = try await store.keepBoth(second.id)
            let keptBytes = try await bytes(kept.id)
            step("keepBoth", kept.id != created.id && keptBytes == Data("conflicting Mac edit\n".utf8) ? "ok" : "mismatch")
            step("revisions", "\(try await revisions(created.id).count)")

            // Google Docs export: a native Doc can be opened only as an export, never edited in place.
            let doc = try await createDocument(named: "Probe Doc", parent: parent)
            do {
                _ = try await store.openSession(doc)
                step("docsReadOnly", "editable")
            } catch {
                step("docsReadOnly", (error as? DriveError) == .permissionDenied && doc.isGoogleDocument ? "ok" : "error \(type(of: error))")
            }
            for id in [session.id, second.id] { await store.releaseCopy(id) }
        } catch is ProbeStop {
        } catch {
            step("error", error is DriveError || error is DriveMutationError ? "\(error)" : "\(type(of: error))")
        }
        if let folder {
            let trashed = try? await client.setTrashed(folder.id, trashed: true)
            step("cleanup", trashed?.trashed == true ? "trashed" : "failed")
        }
        let expected = [
            "create", "v2staleBytesKept", "v2matchBytes", "v2etagChanges", "edit", "editBytes", "editRevisions", "editHeadRevision",
            "conflict", "conflictRemoteKept", "keepBoth", "docsReadOnly",
        ]
        report.passed =
            expected.allSatisfy { report.steps[$0] == "ok" } && report.steps["v2staleIfMatch"] == "412"
            && report.steps["v2matchIfMatch"] == "200" && report.steps["v2oldEtagAfterChange"] == "412"
            && report.steps["cleanup"] == "trashed"
        return report
    }

    private struct ProbeStop: Error {}
    private func fileURL(_ id: String) -> URL { client.mutationURL("files/\(id)") }
    private func atomicSave(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".probe-save-\(UUID().uuidString)")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
    private func status(of request: () async throws -> Int) async -> String {
        do { return "\(try await request())" } catch DriveError.http(let code) { return "\(code)" } catch {
            return "\(type(of: error)).\((error as? DriveError).map { "\($0)" } ?? "")"
        }
    }
    @discardableResult
    private func mediaPatch(_ file: DriveFile, _ data: Data, ifMatch: String?) async throws -> Int {
        var upload = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: false)!
        upload.path = "/upload/" + upload.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/files/" + file.id
        upload.queryItems = [URLQueryItem(name: "uploadType", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        var headers = ["Content-Type": file.mimeType]
        if let ifMatch { headers["If-Match"] = ifMatch }
        let (_, response) = try await client.mutationResponse(upload.url!, method: "PATCH", body: data, headers: headers)
        return response.statusCode
    }
    private struct V2File: Decodable { let etag: String?; let headRevisionId: String? }
    private func v2Metadata(_ id: String) async throws -> V2File {
        try client.decode(V2File.self, try await client.mutationResponse(client.v2FileURL(id, fields: "etag,headRevisionId")).0)
    }
    private func v2Put(_ id: String, _ data: Data, ifMatch: String) async throws -> Int {
        let (_, response) = try await client.mutationResponse(
            client.v2FileURL(id, fields: "id", upload: true), method: "PUT", body: data, headers: ["Content-Type": "text/plain", "If-Match": ifMatch])
        return response.statusCode
    }
    private func bytes(_ id: String) async throws -> Data { try await client.download(client.file(id)).data }
    private struct Revision: Decodable { let id: String; let md5Checksum: String? }
    private func revisions(_ id: String) async throws -> [Revision] {
        var url = URLComponents(url: client.baseURL.appendingPathComponent("files/\(id)/revisions"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "fields", value: "revisions(id,md5Checksum)")]
        struct List: Decodable { let revisions: [Revision]? }
        return try client.decode(List.self, try await client.mutationResponse(url.url!).0).revisions ?? []
    }
    private func createDocument(named name: String, parent: String) async throws -> DriveFile {
        let body: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.document", "parents": [parent]]
        let (data, _) = try await client.mutationResponse(
            client.mutationURL("files"), method: "POST", body: try JSONSerialization.data(withJSONObject: body),
            headers: ["Content-Type": "application/json"])
        return try client.decode(DriveFile.self, data)
    }
}
#endif
