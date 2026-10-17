import Foundation

public typealias DropboxChangeFeed = CloudChangeFeed

extension CloudChangeFeed {
    public init(client: DropboxClient) {
        self.init(
            source: CloudChangeSource(
                scopes: { [weak client] in client == nil ? [] : ["changes"] },
                cursor: { [weak client] in client?.metadataCache.cursor($0) },
                setCursor: { [weak client] token, scope in client?.metadataCache.setCursor(token, scope: scope) },
                initialize: { _ in nil },
                page: { [weak client] _, cursor in
                    guard let client else { throw CancellationError() }
                    return try await dropboxChangePage(client, cursor: cursor)
                },
                isReset: { error in
                    guard let error = error as? DropboxError, case .api(409, let summary) = error else { return false }
                    return summary.hasPrefix("reset")
                },
                reset: { [weak client] _ in
                    guard let client else { throw CancellationError() }
                    client.metadataCache.clear(); client.emit(CloudChangeBatch(reset: true))
                }, waitNeedsCursor: true,
                wait: { [weak client] in
                    guard let client, let cursor = client.metadataCache.cursor("changes") else { throw CancellationError() }
                    var request = URLRequest(url: client.configuration.notifyURL.appendingPathComponent("files/list_folder/longpoll"))
                    request.httpMethod = "POST"; request.timeoutInterval = 155
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": cursor, "timeout": 30])
                    // Notify is deliberately unauthenticated; bearer and namespace headers never leave the API host.
                    let (data, response) = try await client.http.response(request)
                    try DropboxClient.check(data, response)
                    struct Poll: Decodable { var changes: Bool; var backoff: Int? }
                    let poll = try JSONDecoder().decode(Poll.self, from: data)
                    return CloudChangePoll(changes: poll.changes, backoff: Double(max(0, poll.backoff ?? 0)))
                }, invalidPage: DropboxError.invalidResponse))
    }
}
private func dropboxChangePage(_ client: DropboxClient, cursor: String?) async throws -> CloudChangePage {
    let since = client.metadataCache.generation
    let page = try await client.listPage(cursor: cursor, recursive: true)
    guard !page.cursor.isEmpty else { throw DropboxError.invalidResponse }
    return CloudChangePage(
        cursor: page.cursor, hasMore: page.hasMore,
        apply: {
            var current = Dictionary(client.metadataCache.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var updates: [String: DropboxItem] = [:]; var removed = Set<String>()
            // Events are ordered. A move can report the old path deleted and the same ID at its new path.
            for entry in page.entries {
                if entry.tag == "deleted", let path = entry.pathLower {
                    let ids = current.values.filter { $0.pathLower == path || $0.pathLower?.hasPrefix(path + "/") == true }.map(\.id)
                    for id in ids { current[id] = nil; updates[id] = nil; removed.insert(id) }
                } else if entry.tag != "deleted" {
                    let replaced = current.values.filter { $0.pathLower == entry.pathLower && $0.id != entry.id }.map(\.id)
                    for id in replaced { current[id] = nil; updates[id] = nil; removed.insert(id) }
                    current[entry.id] = entry; updates[entry.id] = entry; removed.remove(entry.id)
                }
            }
            let changed = client.metadataCache.learn(Array(updates.values), since: since)
            let paths = Dictionary(client.metadataCache.files.map { ($0.id, $0.pathLower ?? "") }, uniquingKeysWith: { a, _ in a })
            let actualRemoved = client.metadataCache.apply(
                changed, removed: Array(removed),
                belongs: { key, file in
                    file.parentPath == (paths[key] ?? key.lowercased())
                }, retainExisting: { $0 == "shared" }, since: since)
            client.emit(CloudChangeBatch(changed: changed.map { client.contentSource.remoteItem($0) }, removed: actualRemoved))
        })
}
