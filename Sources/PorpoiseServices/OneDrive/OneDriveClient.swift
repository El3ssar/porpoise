import Foundation
import PorpoiseCore

/// Graph wire policy for one drive. Cache, credentials, bounded streaming and range persistence are shared services.
/// A bearer token goes only to the Graph host; download, upload-session and copy-monitor URLs are pre-authenticated
/// capabilities on other hosts and are sent without it.
public final class OneDriveClient: @unchecked Sendable {
    public let accountID: UUID
    public let configuration: OneDriveConfiguration
    public let tokens: CloudOAuthSession
    public let http: CloudHTTPTransport
    public let driveID: String
    public let metadataCache: CloudMetadataCache<OneDriveItem>
    public let journal: CloudJournal<OneDriveOperation>
    public let renditions: CloudRenditionCache
    public let directory: URL
    /// How the pause before a retry is spent (`CloudAuthorizedClient.defaultWait`; tests record it instead).
    let retryWait: @Sendable (TimeInterval) async throws -> Void
    let links = OneDriveLinks()
    private let lock = NSLock()
    private var offline = false
    private var source: OneDriveContentSource?
    private var reachabilityCallback: (@Sendable (Error?) -> Void)?
    private var freshnessCallback: (@Sendable () -> Void)?
    public var onReachability: (@Sendable (Error?) -> Void)? {
        get { lock.withLock { reachabilityCallback } }
        set { lock.withLock { reachabilityCallback = newValue } }
    }
    public var onFreshness: (@Sendable () -> Void)? {
        get { lock.withLock { freshnessCallback } }
        set { lock.withLock { freshnessCallback = newValue } }
    }
    public var isOffline: Bool { lock.withLock { offline } }
    private var feed: OneDriveChangeFeed?
    private var editStore: OneDriveEditStore?
    public var changes: OneDriveChangeFeed {
        lock.withLock {
            if let feed { return feed }; let new = OneDriveChangeFeed(client: self); feed = new; return new
        }
    }
    public var edits: OneDriveEditStore {
        lock.withLock {
            if let editStore { return editStore }; let new = OneDriveEditStore(client: self); editStore = new; return new
        }
    }
    public init(
        accountID: UUID, configuration: OneDriveConfiguration, tokens: CloudOAuthSession, driveID: String, directory: URL,
        http: CloudHTTPTransport = .init(), retryWait: @escaping @Sendable (TimeInterval) async throws -> Void = CloudAuthorizedClient.defaultWait
    ) {
        self.accountID = accountID; self.configuration = configuration; self.tokens = tokens; self.driveID = driveID
        self.directory = directory; self.http = http; self.retryWait = retryWait
        let scoped = directory.appendingPathComponent(cloudObjectKey(driveID))
        metadataCache = CloudMetadataCache(directory: scoped.appendingPathComponent("Metadata"))
        journal = CloudJournal(folder: scoped.appendingPathComponent("Operations"))
        renditions = CloudRenditionCache(directory: scoped.appendingPathComponent("Renditions"))
        enableMetadataRetention()
    }

    // MARK: Requests

    /// `drives/{drive}/root` or `drives/{drive}/items/{id}`, each ID one escaped segment.
    func itemPath(_ id: String) -> String {
        "drives/" + oneDriveEscape(driveID) + (id.isEmpty ? "/root" : "/items/" + oneDriveEscape(id))
    }
    /// A Graph URL from an already escaped relative path.
    func graph(_ path: String, query: [URLQueryItem] = []) -> URL {
        var base = configuration.graphURL.absoluteString; if !base.hasSuffix("/") { base += "/" }
        var c = URLComponents(string: base + path)!
        if !query.isEmpty { c.percentEncodedQueryItems = query.map { .init(name: $0.name, value: $0.value.map(oneDriveEscape)) } }
        return c.url!
    }
    func request(_ url: URL, method: String = "GET", json: Any? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        guard configuration.isGraph(url) else { throw OneDriveError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
    /// Graph's requests with the account's token.
    var authorized: CloudAuthorizedClient {
        CloudAuthorizedClient(
            transport: http,
            token: { [tokens] rejected in
                do { return try await tokens.accessToken(rejectedToken: rejected) } catch is CloudOAuthSessionError { throw OneDriveError.reconnect }
            }, classify: { body, response, idempotent in Self.classify(body, response, idempotent: idempotent) }, wait: retryWait)
    }
    /// Throttled (429) and unavailable (503, with Retry-After) are sent again; another server error only for reads.
    /// https://learn.microsoft.com/graph/throttling
    static func classify(_ body: Data, _ response: HTTPURLResponse, idempotent: Bool) -> CloudHTTPOutcome {
        let error: Error
        do { try check(body, response); return .done } catch let failure { error = failure }
        if [429, 503].contains(response.statusCode) || (idempotent && (500...599).contains(response.statusCode)) { return .retry(error) }
        return .fail(error)
    }
    /// Graph's error resource: `{"error": {"code": …, "message": …}}`. https://learn.microsoft.com/graph/errors
    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (object?["error"] as? [String: Any])?["code"] as? String ?? (object?["error"] as? String) ?? ""
        switch response.statusCode {
        case 401: throw OneDriveError.reconnect
        case 404: throw OneDriveError.notFound
        case 409, 412: throw OneDriveError.conflict
        default: throw OneDriveError.api(response.statusCode, code)
        }
    }
    func reached(_ error: Error?) {
        lock.withLock { offline = error is URLError && (error as? URLError)?.code != .cancelled }
        onReachability?(error)
    }
    func send(_ request: URLRequest, idempotent: Bool) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await authorized.send(request, idempotent: idempotent)
            reached(nil); return result
        } catch { reached(error); throw error }
    }
    func get<T: Decodable>(_ url: URL) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(request(url), idempotent: true).0)
    }

    // MARK: Metadata

    struct Page<Value: Decodable>: Decodable {
        var value: [Value]
        var next: String?
        var delta: String?
        enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink"; case delta = "@odata.deltaLink" }
    }
    /// The next page's URL, which must be on Graph (a bearer goes with it).
    func link(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), configuration.isGraph(url) else { throw OneDriveError.invalidResponse }; return url
    }
    /// The drive's root item: its real ID is every top-level item's parent.
    var rootID: String? { metadataCache.file("")?.id }
    public func metadata(_ id: String) async throws -> OneDriveItem {
        var item: OneDriveItem = try await get(graph(itemPath(id)))
        if item.driveID == nil { item.driveID = driveID }
        guard !item.isDeleted else { throw OneDriveError.notFound }
        metadataCache.remember([item]); if item.isRoot { metadataCache.alias("", to: item) }
        return item
    }
    /// Whether `item` is a member of the listing `key` (a folder ID; "" is the root).
    func belongs(_ key: String, _ item: OneDriveItem, root: String?) -> Bool {
        guard !item.isRoot, let parent = item.parentID else { return false }
        return key.isEmpty ? parent == root : parent == key
    }
    public func list(_ folderID: String = "", onPage: @Sendable ([OneDriveItem], Bool) async -> Void = { _, _ in }) async throws -> [OneDriveItem] {
        do {
            if folderID.isEmpty, rootID == nil { _ = try await metadata("") }
            let read = metadataCache.beginRead()
            defer { withExtendedLifetime(read) {} }
            let since = read.generation
            var files: [String: OneDriveItem] = [:]
            try await CloudPager.each(repeated: OneDriveError.invalidResponse) { (next: String?) in
                let url = try next.map(link) ?? graph(itemPath(folderID) + "/children", query: [.init(name: "$top", value: "200")])
                let page: Page<OneDriveItem> = try await get(url)
                for var item in page.value where !item.isDeleted {
                    if item.driveID == nil { item.driveID = driveID }
                    files[item.id] = item
                }
                await onPage(Array(files.values), page.next == nil)
                return page.next
            }
            let result = files.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            metadataCache.store(result, key: folderID, since: since)
            onFreshness?(); return result
        } catch {
            if isOffline, let cached = metadataCache.snapshot(folderID) { return cached.files }
            throw error
        }
    }
    public struct SearchPage: Sendable { public var items: [OneDriveItem]; public var cursor: String? }
    /// Graph searches names and contents alike; there's no names-only option. The cursor is Graph's next link.
    public func search(_ query: String, in folderID: String = "", cursor: String? = nil) async throws -> SearchPage {
        let url: URL
        if let cursor {
            url = try link(cursor)
        } else {
            let quoted = oneDriveEscape(query.replacingOccurrences(of: "'", with: "''"))
            url = graph(itemPath(folderID) + "/search(q='" + quoted + "')", query: [.init(name: "$top", value: "100")])
        }
        let page: Page<OneDriveItem> = try await get(url)
        let items = page.value.filter { !$0.isDeleted }.map { item -> OneDriveItem in
            var item = item; if item.driveID == nil { item.driveID = driveID }; return item
        }
        metadataCache.remember(items.filter { $0.driveID == driveID })
        return SearchPage(items: items, cursor: page.next)
    }
    /// Items others shared, each its remote target (in its owner's drive).
    public func sharedWithMe() async throws -> [OneDriveItem] {
        var items: [OneDriveItem] = []
        try await CloudPager.each(repeated: OneDriveError.invalidResponse) { (next: String?) in
            let page: Page<OneDriveItem> = try await get(try next.map(link) ?? graph("me/drive/sharedWithMe"))
            items += page.value.filter { !$0.isDeleted && $0.driveID != nil }
            return page.next
        }
        items = Array(Dictionary(items.map { ($0.driveID! + "/" + $0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        metadataCache.store(items, key: "collection:shared"); return items
    }
    /// A client for another drive (a shared item's owner's), with the same sign-in and its own cache and journal.
    public func driveClient(_ driveID: String) -> OneDriveClient {
        guard driveID != self.driveID else { return self }
        let client = OneDriveClient(
            accountID: accountID, configuration: configuration, tokens: tokens, driveID: driveID, directory: directory, http: http,
            retryWait: retryWait)
        client.onReachability = onReachability; client.onFreshness = onFreshness; return client
    }
    /// A 256-pixel rendition, fetched from the pre-authenticated URL Graph names, without the bearer.
    public func thumbnail(_ item: OneDriveItem) async throws -> URL {
        guard item.canDownload, let revision = item.revision else { throw OneDriveError.invalidLocation }
        return try await renditions.file(key: "thumbnail:" + item.id + ":" + revision, name: "thumbnail.jpg") {
            struct Size: Decodable { var url: String }
            struct Thumbnails: Decodable { var medium: Size? }
            let page: Page<Thumbnails> = try await self.get(
                self.graph(self.itemPath(item.id) + "/thumbnails", query: [.init(name: "select", value: "medium")]))
            guard let raw = page.value.first?.medium?.url, let url = URL(string: raw), url.scheme == "https" || self.configuration.isGraph(url)
            else { throw OneDriveError.notFound }
            let (data, response) = try await self.http.response(URLRequest(url: url))
            try Self.check(data, response); return data
        }
    }
    public struct Quota: Decodable, Equatable, Sendable { public var used: Int64?; public var total: Int64? }
    public func quota() async throws -> Quota {
        struct Drive: Decodable { var quota: Quota? }
        let drive: Drive = try await get(graph("drives/" + oneDriveEscape(driveID), query: [.init(name: "select", value: "quota")]))
        return drive.quota ?? Quota()
    }
    public var contentSource: OneDriveContentSource {
        lock.withLock {
            if let source { return source }; let new = OneDriveContentSource(client: self); source = new; return new
        }
    }
    func emit(_ batch: CloudChangeBatch) { lock.withLock { source }?.onChanges?(batch); onFreshness?() }
}
