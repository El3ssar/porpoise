import Foundation

/// Serializes cursor application, longpoll backoff and lifecycle. Cursors are scoped to the client's namespace.
public actor DropboxChangeFeed {
    private weak var client: DropboxClient?
    private var task: Task<Void, Never>?
    private var flight: (UUID, Task<Void, Error>)?
    private var nextPoll = Date.distantPast
    public init(client: DropboxClient) { self.client = client }
    public func check() async throws {
        if let flight { return try await flight.1.value }
        let id = UUID()
        let task = Task { try await self.applyPages() }; flight = (id, task)
        defer { if flight?.0 == id { flight = nil } }
        try await task.value
    }
    private func applyPages() async throws {
        guard let client else { return }
        var cursor = client.metadataCache.cursor("changes")
        var seen = Set<String>()
        repeat {
            let page: DropboxPage
            do { page = try await client.listPage(cursor: cursor, recursive: true) } catch DropboxError.api(409, let summary)
                where summary.hasPrefix("reset") && cursor != nil
            {
                client.metadataCache.clear()
                client.emit(CloudChangeBatch(reset: true)); cursor = nil; seen.removeAll(); continue
            }
            try Task.checkCancellation()
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
            let changed = Array(updates.values)
            let paths = current.mapValues { $0.pathLower ?? "" }
            client.metadataCache.apply(
                changed, removed: Array(removed),
                belongs: { key, file in
                    file.parentPath == (paths[key] ?? key.lowercased())
                }, retainExisting: { $0 == "shared" })
            client.emit(CloudChangeBatch(changed: changed.map { client.contentSource.remoteItem($0) }, removed: Array(removed)))
            // Publish the cursor only after this page is applied; replay after a crash is idempotent.
            client.metadataCache.setCursor(page.cursor, scope: "changes")
            cursor = page.cursor
            if !page.hasMore { break }
            guard seen.insert(page.cursor).inserted else { throw DropboxError.invalidResponse }
        } while true
    }
    public func pollOnce() async throws -> Bool {
        guard let client else { return false }
        if client.metadataCache.cursor("changes") == nil { try await check() }
        guard let cursor = client.metadataCache.cursor("changes") else { throw DropboxError.invalidResponse }
        let delay = nextPoll.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        var request = URLRequest(url: client.configuration.notifyURL.appendingPathComponent("files/list_folder/longpoll"))
        request.httpMethod = "POST"; request.timeoutInterval = 155
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": cursor, "timeout": 30])
        // Longpoll is a no-auth endpoint. Never send a bearer or namespace header to the notify host.
        let (data, response) = try await client.http.response(request)
        do { try DropboxClient.check(data, response) } catch DropboxError.api(409, let summary) where summary.hasPrefix("reset") {
            client.metadataCache.clear(); client.emit(CloudChangeBatch(reset: true))
            try await check(); return true
        }
        struct Poll: Decodable { var changes: Bool; var backoff: Int? }
        let poll = try JSONDecoder().decode(Poll.self, from: data)
        nextPoll = Date().addingTimeInterval(Double(max(0, poll.backoff ?? 0)))
        if poll.changes { try await check() }; return poll.changes
    }
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do { _ = try await self.pollOnce() } catch { if Task.isCancelled { break }; try? await Task.sleep(nanoseconds: 5_000_000_000) }
            }
        }
    }
    public func stop() { task?.cancel(); task = nil; flight?.1.cancel(); flight = nil }
}
