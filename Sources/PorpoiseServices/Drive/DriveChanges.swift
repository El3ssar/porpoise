import Foundation
import PorpoiseCore

extension DriveClient {
    public func startPolling(interval: TimeInterval = 45) {
        stopPolling()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.pollChanges() } catch {}
                do { try await Task.sleep(nanoseconds: UInt64(max(30, interval) * 1_000_000_000)) } catch { return }
            }
        }
        lock.withLock { polling = task }
    }
    public func stopPolling() {
        let task = lock.withLock {
            let task = polling; polling = nil; return task
        }
        task?.cancel()
    }
    /// Advances each cursor only after applying its page. Replays are harmless after interruption.
    public func pollChanges() async throws {
        guard
            lock.withLock({
                if pollingChanges { return false }; pollingChanges = true; return true
            })
        else { return }
        defer { lock.withLock { pollingChanges = false } }
        for scope in ["user"] + metadataCache.sharedDriveIDs {
            var query = [URLQueryItem(name: "supportsAllDrives", value: "true")]
            if scope != "user" { query.append(URLQueryItem(name: "driveId", value: scope)) }
            var cursor = metadataCache.cursor(scope)
            if cursor == nil {
                struct Start: Decodable { let startPageToken: String }
                cursor = try decode(Start.self, await request("changes/startPageToken", query: query)).startPageToken
                metadataCache.setCursor(cursor, scope: scope)
            }
            var seen: Set<String> = []
            while let token = cursor {
                guard seen.insert(token).inserted else { throw DriveError.invalidResponse }
                struct Page: Decodable {
                    struct Change: Decodable { let fileId: String?; let removed: Bool?; let file: DriveFile? }
                    let changes: [Change]?
                    let nextPageToken: String?
                    let newStartPageToken: String?
                }
                let page: Page
                do {
                    page = try decode(
                        Page.self,
                        await request(
                            "changes",
                            query: query + [
                                URLQueryItem(name: "pageToken", value: token), URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fields)))"),
                            ]))
                } catch DriveError.http(410) {
                    metadataCache.setCursor(nil, scope: scope)
                    metadataCache.invalidate()
                    NotificationCenter.default.post(name: Self.changed, object: accountID)
                    return
                }
                let changes = page.changes ?? []
                if !changes.isEmpty {
                    let files = changes.compactMap(\.file)
                    let removed = changes.filter { $0.removed == true || $0.file?.trashed == true }.compactMap(\.fileId)
                    metadataCache.apply(files, removed: removed)
                    lock.withLock {
                        for id in removed { cache[id] = nil }; for file in files { cache[file.id] = file }
                    }
                    (RemoteFS.provider(for: DriveLocation(accountID: accountID).url) as? DriveProvider)?.invalidate(preserveDisk: true)
                    NotificationCenter.default.post(name: Self.changed, object: accountID)
                }
                guard let next = page.nextPageToken ?? page.newStartPageToken else { throw DriveError.invalidResponse }
                metadataCache.setCursor(next, scope: scope)
                cursor = page.nextPageToken
            }
        }
    }

    /// Remote search is paged and explicitly scoped; no local content index is implied.
    public func search(_ text: String, in location: DriveLocation, fullText: Bool = false, pageToken: String? = nil) async throws -> DrivePage {
        guard location.accountID == accountID else { throw DriveError.invalidLocation }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var filter = "trashed = false and \(fullText ? "fullText" : "name") contains '\(escaped)'"
        var driveID: String?
        switch location.collection {
        case .folder(let id, let drive):
            guard DriveLink.isValidID(id) else { throw DriveError.invalidLocation }
            filter += " and '\(id)' in parents"; driveID = drive
        case .sharedWithMe: filter += " and sharedWithMe = true"
        case .sharedDrives: throw DriveError.invalidLocation
        case .myDrive: break
        }
        var query = [
            URLQueryItem(name: "q", value: filter), URLQueryItem(name: "pageSize", value: "200"),
            URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(\(Self.fields))"),
            URLQueryItem(name: "corpora", value: driveID == nil ? "user" : "drive"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"), URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        if let driveID { query.append(URLQueryItem(name: "driveId", value: driveID)) }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        struct Page: Decodable { let files: [DriveFile]?; let nextPageToken: String?; let incompleteSearch: Bool? }
        let page = try decode(Page.self, await request("files", query: query))
        guard page.incompleteSearch != true else { throw DriveError.invalidResponse }
        let files = page.files ?? []
        guard files.allSatisfy({ DriveLink.isValidID($0.id) }) else { throw DriveError.invalidResponse }
        remember(files)
        return DrivePage(files: files, nextPageToken: page.nextPageToken)
    }
}
