import Foundation
import PorpoiseCore

extension DriveClient {
    public func startPolling(interval: TimeInterval = CloudAccountRefreshPolicy.interval) {
        let feed = changes
        let generation = lock.withLock {
            pollingGeneration += 1; return pollingGeneration
        }
        Task { await feed.setPolling(true, generation: generation, interval: max(30, interval)) }
    }
    public func stopPolling() {
        let (feed, generation) = lock.withLock {
            pollingGeneration += 1; return (changeFeed, pollingGeneration)
        }
        if let feed { Task { await feed.setPolling(false, generation: generation, interval: 30) } }
    }
    public func pollChanges() async throws { try await changes.check() }
    /// Remote search is paged and explicitly scoped; no local content index is implied.
    public func search(_ text: String, in location: DriveLocation, fullText: Bool = false, pageToken: String? = nil) async throws -> DrivePage {
        guard location.accountID == accountID else { throw DriveError.invalidLocation }
        let since = metadataCache.generation
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
        return DrivePage(files: learned(files, since: since), nextPageToken: page.nextPageToken)
    }
}

extension CloudChangeFeed {
    public init(client: DriveClient) {
        self.init(
            source: CloudChangeSource(
                scopes: { [weak client] in client.map { ["user"] + $0.metadataCache.sharedDriveIDs } ?? [] },
                cursor: { [weak client] scope in
                    guard let client, client.metadataCache.cursor("reset:" + scope) == nil else { return nil }
                    return client.metadataCache.cursor(scope)
                },
                setCursor: { [weak client] token, scope in client?.metadataCache.setCursor(token, scope: scope) },
                initialize: { [weak client] scope in
                    guard let client else { throw CancellationError() }
                    if let token = client.metadataCache.cursor("reset:" + scope) {
                        try await driveResetBaseline(client, scope: scope, token: token); return token
                    }
                    return try await driveStartCursor(client, scope: scope)
                },
                page: { [weak client] scope, cursor in
                    guard let client, let cursor else { throw DriveError.invalidResponse }
                    return try await driveChangePage(client, scope: scope, cursor: cursor)
                }, isReset: { ($0 as? DriveError) == .http(410) },
                reset: { [weak client] scope in
                    guard let client else { throw CancellationError() }
                    let token = try await driveStartCursor(client, scope: scope)
                    client.metadataCache.setCursor(token, scope: "reset:" + scope)
                    client.metadataCache.setCursor(nil, scope: scope)
                    try await driveResetBaseline(client, scope: scope, token: token)
                },
                waitNeedsCursor: false,
                wait: { [weak client] in
                    guard client != nil else { throw CancellationError() }
                    return CloudChangePoll(changes: true, backoff: CloudAccountRefreshPolicy.interval)
                }, invalidPage: DriveError.invalidResponse))
    }
}
private func driveChangeQuery(_ scope: String) -> [URLQueryItem] {
    var query = [URLQueryItem(name: "supportsAllDrives", value: "true")]
    if scope != "user" { query.append(URLQueryItem(name: "driveId", value: scope)) }
    return query
}
private func driveChangePage(_ client: DriveClient, scope: String, cursor: String) async throws -> CloudChangePage {
    struct Page: Decodable {
        struct Change: Decodable { let fileId: String?; let removed: Bool?; let file: DriveFile? }
        let changes: [Change]?
        let nextPageToken: String?
        let newStartPageToken: String?
    }
    let since = client.metadataCache.generation
    let page = try client.decode(
        Page.self,
        await client.request(
            "changes",
            query: driveChangeQuery(scope) + [
                URLQueryItem(name: "pageToken", value: cursor), URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(DriveClient.fields)))"),
            ]))
    guard let next = page.nextPageToken ?? page.newStartPageToken, !next.isEmpty else { throw DriveError.invalidResponse }
    return CloudChangePage(
        cursor: next, hasMore: page.nextPageToken != nil,
        apply: {
            let changes = page.changes ?? []
            if !changes.isEmpty {
                let removed = changes.filter { $0.removed == true || $0.file?.trashed == true }.compactMap(\.fileId)
                // A change made here after this page was asked for is newer than what the page says.
                let files = client.metadataCache.learn(changes.compactMap(\.file).filter { !removed.contains($0.id) }, since: since)
                let actualRemoved = client.metadataCache.apply(files, removed: removed, since: since)
                let source = client.contentSource
                client.emitContentChanges(.init(changed: files.filter { !removed.contains($0.id) }.map(source.remoteItem), removed: actualRemoved))
                (RemoteFS.provider(for: DriveLocation(accountID: client.accountID).url) as? DriveProvider)?.invalidate(preserveDisk: true)
                NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: client.accountID.uuidString.lowercased())
            }
        })
}

private func driveStartCursor(_ client: DriveClient, scope: String) async throws -> String {
    struct Start: Decodable { let startPageToken: String }
    let bytes = try await client.request("changes/startPageToken", query: driveChangeQuery(scope))
    let token = try client.decode(Start.self, bytes).startPageToken
    guard !token.isEmpty else { throw DriveError.invalidResponse }
    return token
}

/// The token precedes the baseline; replay then includes changes made during enumeration.
private func driveResetBaseline(_ client: DriveClient, scope: String, token: String) async throws {
    let since = client.metadataCache.generation
    let previous = client.metadataCache.files.filter { scope == "user" ? $0.driveId == nil : $0.driveId == scope }
    var files: [DriveFile] = []
    try await CloudPager.each(repeated: DriveError.invalidResponse) { (pageToken: String?) in
        var query = [
            URLQueryItem(name: "q", value: "trashed = false"), URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "supportsAllDrives", value: "true"), URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "corpora", value: scope == "user" ? "user" : "drive"),
            URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(\(DriveClient.fields))"),
        ]
        if scope != "user" { query.append(URLQueryItem(name: "driveId", value: scope)) }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        struct Page: Decodable { let files: [DriveFile]?; let nextPageToken: String?; let incompleteSearch: Bool? }
        let page = try client.decode(Page.self, await client.request("files", query: query))
        guard page.incompleteSearch != true else { throw DriveError.invalidResponse }
        files += page.files ?? []; return page.nextPageToken
    }
    try Task.checkCancellation()
    let ids = Set(files.map(\.id)), learned = client.metadataCache.learn(files, since: since)
    let removed = client.metadataCache.apply(learned, removed: previous.filter { !ids.contains($0.id) }.map(\.id), since: since)
    client.metadataCache.invalidateScope(scope)
    client.emitContentChanges(.init(changed: learned.map(client.contentSource.remoteItem), removed: removed, reset: true))
    client.metadataCache.setCursor(token, scope: scope)
    client.metadataCache.setCursor(nil, scope: "reset:" + scope)
    NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: client.accountID.uuidString.lowercased())
}
