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
            let (updates, removed) = dropboxPageChanges(page.entries, cached: client.metadataCache.files)
            let changed = client.metadataCache.learn(updates, since: since)
            let paths = Dictionary(client.metadataCache.files.map { ($0.id, $0.pathLower ?? "") }, uniquingKeysWith: { a, _ in a })
            let actualRemoved = client.metadataCache.apply(
                changed, removed: Array(removed),
                belongs: { key, file in
                    file.parentPath == (paths[key] ?? key.lowercased())
                }, retainExisting: { $0 == "collection:shared" }, since: since)
            client.emit(CloudChangeBatch(changed: changed.map { client.contentSource.remoteItem($0) }, removed: actualRemoved))
        })
}

/// What a page of changes does to the cached items: the items it adds or changes, and the IDs it removes. Events are
/// ordered; a move can report the old path deleted and the same ID at its new path. Looks paths up in an index, so
/// a page costs O(cached + page), not O(cached × page).
func dropboxPageChanges(_ entries: [DropboxItem], cached: [DropboxItem]) -> (updates: [DropboxItem], removed: Set<String>) {
    var current = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var paths = DropboxPathIndex()
    for item in current.values { paths.insert(item.id, at: item.pathLower) }
    var updates: [String: DropboxItem] = [:]; var removed = Set<String>()
    func remove(_ id: String) {
        if let item = current.removeValue(forKey: id) { paths.remove(id, at: item.pathLower) }
        updates[id] = nil; removed.insert(id)
    }
    for entry in entries {
        if entry.tag == "deleted", let path = entry.pathLower {
            for id in paths.subtree(path) { remove(id) }
        } else if entry.tag != "deleted" {
            for id in paths.ids(at: entry.pathLower) where id != entry.id { remove(id) }
            if let old = current[entry.id] { paths.remove(entry.id, at: old.pathLower) }
            current[entry.id] = entry; paths.insert(entry.id, at: entry.pathLower)
            updates[entry.id] = entry; removed.remove(entry.id)
        }
    }
    return (Array(updates.values), removed)
}

/// Item IDs by lowercased path, and each path's children, ancestors included even when they aren't cached: what's
/// under a deleted folder without a scan of the account.
struct DropboxPathIndex {
    private var ids: [String?: Set<String>] = [:]
    private var children: [String: Set<String>] = [:]
    func ids(at path: String?) -> Set<String> { ids[path] ?? [] }
    mutating func insert(_ id: String, at path: String?) {
        ids[path, default: []].insert(id)
        guard var child = path else { return }
        while let slash = child.lastIndex(of: "/"), slash > child.startIndex {
            let parent = String(child[..<slash])
            // Linked before: so are its ancestors.
            guard children[parent, default: []].insert(child).inserted else { break }
            child = parent
        }
    }
    /// Links to children stay: a path without IDs is skipped when walked.
    mutating func remove(_ id: String, at path: String?) {
        ids[path]?.remove(id)
        if ids[path]?.isEmpty == true { ids[path] = nil }
    }
    /// The IDs at `path` and anywhere under it.
    func subtree(_ path: String) -> [String] {
        var result: [String] = [], pending = [path]
        while let next = pending.popLast() {
            result += ids[next] ?? []
            pending += children[next] ?? []
        }
        return result
    }
}
