import Foundation
import PorpoiseCore

public typealias BoxChangeFeed = CloudChangeFeed

/// The account's event stream (https://developer.box.com/guides/events/user-events/for-user/). The cursor is Box's
/// opaque stream position, started from `now` (no enumeration of the whole account). The wait is Box's long poll: an
/// unauthenticated realtime URL, asked for with OPTIONS /events, that answers `new_change` or `reconnect`
/// (https://developer.box.com/guides/events/user-events/polling/).
extension CloudChangeFeed {
    public init(client: BoxClient) {
        self.init(
            source: CloudChangeSource(
                scopes: { [weak client] in client == nil ? [] : ["changes"] },
                cursor: { [weak client] in client?.metadataCache.cursor($0) },
                setCursor: { [weak client] token, scope in client?.metadataCache.setCursor(token, scope: scope) },
                initialize: { [weak client] _ in
                    guard let client else { throw CancellationError() }
                    let page: BoxEvents = try await client.get(client.api("events", query: [.init(name: "stream_position", value: "now")]))
                    guard let position = page.position else { throw BoxError.invalidResponse }
                    return position
                },
                page: { [weak client] _, cursor in
                    guard let client, let cursor else { throw CancellationError() }
                    return try await boxChangePage(client, cursor: cursor)
                },
                // An expired or unknown stream position: start again from now.
                isReset: { error in
                    guard let error = error as? BoxError, case .api(let status, _) = error else { return false }
                    return status == 400 || status == 410
                },
                reset: { [weak client] _ in
                    guard let client else { throw CancellationError() }
                    client.metadataCache.clear(); client.emit(CloudChangeBatch(reset: true))
                }, waitNeedsCursor: true,
                wait: { [weak client] in
                    guard let client, let cursor = client.metadataCache.cursor("changes") else { throw CancellationError() }
                    return try await boxLongPoll(client, cursor: cursor)
                }, invalidPage: BoxError.invalidResponse))
    }
}

struct BoxEvents: Decodable {
    struct Event: Decodable {
        var id: String?
        var type: String?
        var source: BoxItem?
        enum CodingKeys: String, CodingKey { case id = "event_id", type = "event_type", source }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id); type = try c.decodeIfPresent(String.self, forKey: .type)
            // A comment, task or collaboration is not an item: it changes nothing listed here.
            source = try? c.decodeIfPresent(BoxItem.self, forKey: .source)
        }
    }
    var entries: [Event]
    var count: Int?
    var position: String?
    enum CodingKeys: String, CodingKey { case entries, count = "chunk_size", position = "next_stream_position" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([Event].self, forKey: .entries) ?? []
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        // Box documents a number or a string.
        position = try (try? c.decodeIfPresent(String.self, forKey: .position)) ?? c.decodeIfPresent(Int64.self, forKey: .position).map(String.init)
    }
}

/// Events whose item has left where it was listed: trashed, deleted, or (for a share) no longer reachable.
private let boxRemovals: Set<String> = ["ITEM_TRASH", "ITEM_DELETE", "ITEM_UNSHARED", "COLLAB_REMOVE", "ITEM_REMOVED"]
/// How many events one page asks for (Box's most).
let boxEventLimit = 500

private func boxChangePage(_ client: BoxClient, cursor: String) async throws -> CloudChangePage {
    let read = client.metadataCache.beginRead()
    defer { withExtendedLifetime(read) {} }
    let since = read.generation
    let page: BoxEvents = try await client.get(
        client.api(
            "events",
            query: [
                .init(name: "stream_position", value: cursor), .init(name: "stream_type", value: "changes"),
                .init(name: "limit", value: String(boxEventLimit)),
            ]))
    guard let next = page.position else { throw BoxError.invalidResponse }
    // Box may give fewer than asked while more follow: the stream is read until a page brings nothing.
    let hasMore = !page.entries.isEmpty && next != cursor
    return CloudChangePage(
        cursor: next, hasMore: hasMore,
        apply: { [read] in
            defer { withExtendedLifetime(read) {} }
            var current = Dictionary(client.metadataCache.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var updates: [String: BoxItem] = [:]; var removed = Set<String>()
            var children: [String: [String]]?
            // Ordered, and Box may repeat an event: applying one twice changes nothing.
            var seen = Set<String>()
            for event in page.entries {
                guard let entry = event.source, event.id.map({ seen.insert($0).inserted }) ?? true else { continue }
                if entry.isDeleted || boxRemovals.contains(event.type ?? "") {
                    // A trashed folder's descendants aren't reported one by one: they go with it.
                    if children == nil { children = boxChildren(current.values) }
                    var gone = [entry.id]
                    while let id = gone.popLast() {
                        guard current[id] != nil || id == entry.id else { continue }
                        current[id] = nil; updates[id] = nil; removed.insert(id)
                        gone += (children?[id] ?? []).filter { current[$0]?.parentID == id }
                    }
                } else if !entry.isRoot {
                    if let parent = entry.parentID { children?[parent, default: []].append(entry.id) }
                    current[entry.id] = entry; updates[entry.id] = entry; removed.remove(entry.id)
                }
            }
            let changed = client.metadataCache.learn(Array(updates.values), since: since)
            let actualRemoved = client.metadataCache.apply(
                changed, removed: Array(removed), belongs: { key, file in client.belongs(key, file) }, since: since)
            client.emit(CloudChangeBatch(changed: changed.map { client.contentSource.remoteItem($0) }, removed: actualRemoved))
        })
}

private func boxLongPoll(_ client: BoxClient, cursor: String) async throws -> CloudChangePoll {
    struct Servers: Decodable {
        struct Server: Decodable { var url: String; var retry_timeout: TimeInterval? }
        var entries: [Server]
    }
    let (data, _) = try await client.send(client.request(client.api("events"), method: "OPTIONS"), idempotent: true)
    guard let server = try JSONDecoder().decode(Servers.self, from: data).entries.first, var c = URLComponents(string: server.url),
        c.scheme == "https" || c.scheme == "http", c.user == nil, c.password == nil
    else { throw BoxError.invalidResponse }
    c.queryItems = (c.queryItems ?? []).filter { $0.name != "stream_position" } + [.init(name: "stream_position", value: cursor)]
    guard let url = c.url else { throw BoxError.invalidResponse }
    // The realtime server is another host: no bearer goes there.
    var request = URLRequest(url: url)
    request.timeoutInterval = min(client.configuration.longPollTimeout, (server.retry_timeout ?? 600) + 10)
    let (body, response) = try await client.http.response(request)
    try BoxClient.check(body, response)
    struct Message: Decodable { var message: String }
    let message = try JSONDecoder().decode(Message.self, from: body).message
    return CloudChangePoll(changes: message == "new_change", backoff: 0)
}

/// Each folder's children's IDs, by the folder's ID.
func boxChildren<Items: Sequence>(_ items: Items) -> [String: [String]] where Items.Element == BoxItem {
    var children: [String: [String]] = [:]
    for item in items { if let parent = item.parentID { children[parent, default: []].append(item.id) } }
    return children
}
