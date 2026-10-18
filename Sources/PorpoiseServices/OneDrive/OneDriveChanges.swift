import Foundation
import PorpoiseCore

public typealias OneDriveChangeFeed = CloudChangeFeed

/// The drive's delta feed (https://learn.microsoft.com/graph/api/driveitem-delta). The cursor is Graph's opaque delta or
/// next link; it starts at `token=latest` (no enumeration of the whole drive). Graph has no long poll for a desktop app:
/// the wait reads the delta link (a read changes nothing on the server) and says whether it has anything.
extension CloudChangeFeed {
    public init(client: OneDriveClient) {
        self.init(
            source: CloudChangeSource(
                scopes: { [weak client] in client == nil ? [] : ["changes"] },
                cursor: { [weak client] in client?.metadataCache.cursor($0) },
                setCursor: { [weak client] token, scope in client?.metadataCache.setCursor(token, scope: scope) },
                initialize: { [weak client] _ in
                    guard let client else { throw CancellationError() }
                    var cursor: String?
                    try await CloudPager.each(repeated: OneDriveError.invalidResponse) { (next: String?) in
                        let url =
                            try next.map(client.link) ?? client.graph(client.itemPath("") + "/delta", query: [.init(name: "token", value: "latest")])
                        let page: OneDriveClient.Page<OneDriveItem> = try await client.get(url)
                        cursor = page.delta; return page.delta == nil ? page.next : nil
                    }
                    guard let cursor else { throw OneDriveError.invalidResponse }
                    return cursor
                },
                page: { [weak client] _, cursor in
                    guard let client, let cursor else { throw CancellationError() }
                    return try await oneDriveChangePage(client, cursor: cursor)
                },
                // 410 Gone (resyncRequired…): the link expired; start again from the latest state.
                isReset: { error in
                    guard let error = error as? OneDriveError, case .api(410, _) = error else { return false }
                    return true
                },
                reset: { [weak client] _ in
                    guard let client else { throw CancellationError() }
                    client.metadataCache.clear(); client.emit(CloudChangeBatch(reset: true))
                }, waitNeedsCursor: true,
                wait: { [weak client] in
                    guard let client, let cursor = client.metadataCache.cursor("changes") else { throw CancellationError() }
                    let page: OneDriveClient.Page<OneDriveItem> = try await client.get(try client.link(cursor))
                    return CloudChangePoll(changes: !page.value.isEmpty || page.next != nil, backoff: client.configuration.pollInterval)
                }, invalidPage: OneDriveError.invalidResponse))
    }
}

private func oneDriveChangePage(_ client: OneDriveClient, cursor: String) async throws -> CloudChangePage {
    let since = client.metadataCache.generation
    let page: OneDriveClient.Page<OneDriveItem> = try await client.get(try client.link(cursor))
    guard let next = page.next ?? page.delta else { throw OneDriveError.invalidResponse }
    return CloudChangePage(
        cursor: next, hasMore: page.next != nil,
        apply: {
            var current = Dictionary(client.metadataCache.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var updates: [String: OneDriveItem] = [:]; var removed = Set<String>()
            // Each folder's children, made at the first deletion and kept as entries move; a link is checked when used.
            var children: [String: [String]]?
            // Ordered: a deleted folder's descendants may not be listed (OneDrive for Business); they go with it.
            for var entry in page.value {
                if entry.driveID == nil { entry.driveID = client.driveID }
                if entry.isDeleted {
                    if children == nil { children = oneDriveChildren(current.values) }
                    var gone = [entry.id]
                    while let id = gone.popLast() {
                        guard current[id] != nil || id == entry.id else { continue }
                        current[id] = nil; updates[id] = nil; removed.insert(id)
                        gone += (children?[id] ?? []).filter { current[$0]?.parentID == id }
                    }
                } else {
                    if let parent = entry.parentID { children?[parent, default: []].append(entry.id) }
                    if entry.isRoot {
                        client.metadataCache.alias("", to: entry); current[entry.id] = entry
                    } else {
                        current[entry.id] = entry; updates[entry.id] = entry; removed.remove(entry.id)
                    }
                }
            }
            let changed = client.metadataCache.learn(Array(updates.values), since: since)
            let root = client.rootID
            let actualRemoved = client.metadataCache.apply(
                changed, removed: Array(removed), belongs: { key, file in client.belongs(key, file, root: root) },
                retainExisting: { $0 == "collection:shared" }, since: since)
            client.emit(CloudChangeBatch(changed: changed.map { client.contentSource.remoteItem($0) }, removed: actualRemoved))
        })
}

/// Each folder's children's IDs, by the folder's ID.
func oneDriveChildren<Items: Sequence>(_ items: Items) -> [String: [String]] where Items.Element == OneDriveItem {
    var children: [String: [String]] = [:]
    for item in items { if let parent = item.parentID { children[parent, default: []].append(item.id) } }
    return children
}
