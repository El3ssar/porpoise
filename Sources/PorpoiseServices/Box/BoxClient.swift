import Foundation
import PorpoiseCore

/// Box wire policy for one account. Cache, credentials, bounded streaming and range persistence are shared services.
/// A bearer token goes only to the API and upload hosts; download URLs (dl.boxcloud.com) and the events realtime server
/// are capabilities on other hosts and are requested without it, and redirects from the API are never followed with it.
public final class BoxClient: @unchecked Sendable {
    public let accountID: UUID
    public let configuration: BoxConfiguration
    public let tokens: CloudOAuthSession
    public let http: CloudHTTPTransport
    public let metadataCache: CloudMetadataCache<BoxItem>
    public let journal: CloudJournal<BoxOperation>
    public let renditions: CloudRenditionCache
    public let directory: URL
    /// How the pause before a retry is spent (`CloudAuthorizedClient.defaultWait`; tests record it instead).
    let retryWait: @Sendable (TimeInterval) async throws -> Void
    let links = BoxLinks()
    private let lock = NSLock()
    private var offline = false
    private var source: BoxContentSource?
    private var reachabilityCallback: (@Sendable (Error?) -> Void)?
    private var freshnessCallback: (@Sendable () -> Void)?
    /// What each item this session moved to the trash was, so Undo names the right API (Box has none for "an item").
    private var trashed: [String: BoxItem.Kind] = [:]
    public var onReachability: (@Sendable (Error?) -> Void)? {
        get { lock.withLock { reachabilityCallback } }
        set { lock.withLock { reachabilityCallback = newValue } }
    }
    public var onFreshness: (@Sendable () -> Void)? {
        get { lock.withLock { freshnessCallback } }
        set { lock.withLock { freshnessCallback = newValue } }
    }
    public var isOffline: Bool { lock.withLock { offline } }
    private var feed: BoxChangeFeed?
    private var editStore: BoxEditStore?
    public var changes: BoxChangeFeed {
        lock.withLock {
            if let feed { return feed }; let new = BoxChangeFeed(client: self); feed = new; return new
        }
    }
    public var edits: BoxEditStore {
        lock.withLock {
            if let editStore { return editStore }; let new = BoxEditStore(client: self); editStore = new; return new
        }
    }
    public init(
        accountID: UUID, configuration: BoxConfiguration, tokens: CloudOAuthSession, directory: URL, http: CloudHTTPTransport = .init(),
        retryWait: @escaping @Sendable (TimeInterval) async throws -> Void = CloudAuthorizedClient.defaultWait
    ) {
        self.accountID = accountID; self.configuration = configuration; self.tokens = tokens
        self.directory = directory; self.http = http; self.retryWait = retryWait
        let scoped = directory.appendingPathComponent("Account")
        metadataCache = CloudMetadataCache(directory: scoped.appendingPathComponent("Metadata"))
        journal = CloudJournal(folder: scoped.appendingPathComponent("Operations"))
        renditions = CloudRenditionCache(directory: scoped.appendingPathComponent("Renditions"))
        enableMetadataRetention()
    }

    // MARK: Requests

    /// The fields every item is read with: enough to list, verify and change it.
    static let fields = "type,id,name,etag,size,sha1,file_version,parent,modified_at,item_status"
    /// `files/{id}`, `folders/{id}` or `web_links/{id}`, the ID one escaped segment.
    func itemPath(_ id: String, _ kind: BoxItem.Kind) -> String {
        let family = kind == .folder ? "folders/" : kind == .file ? "files/" : "web_links/"
        return family + boxEscape(id)
    }
    /// An API (or, with `upload`, upload host) URL from an already escaped relative path.
    func api(_ path: String, query: [URLQueryItem] = [], upload: Bool = false) -> URL {
        var base = (upload ? configuration.uploadURL : configuration.apiURL).absoluteString; if !base.hasSuffix("/") { base += "/" }
        var c = URLComponents(string: base + path)!
        if !query.isEmpty { c.percentEncodedQueryItems = query.map { .init(name: $0.name, value: $0.value.map(boxEscape)) } }
        return c.url!
    }
    func request(_ url: URL, method: String = "GET", json: Any? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        guard configuration.isAPI(url) else { throw BoxError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
    /// Box's requests with the account's token.
    var authorized: CloudAuthorizedClient { authorized(http) }
    /// Requests whose redirect is the answer (a download or thumbnail location), never followed with the bearer.
    var unredirected: CloudAuthorizedClient {
        authorized(http.withoutRedirects) { body, response, idempotent in
            (300...399).contains(response.statusCode) ? .done : Self.classify(body, response, idempotent: idempotent)
        }
    }
    private func authorized(_ transport: CloudHTTPTransport, classify: CloudAuthorizedClient.Classify? = nil) -> CloudAuthorizedClient {
        CloudAuthorizedClient(
            transport: transport,
            token: { [tokens] rejected in
                do { return try await tokens.accessToken(rejectedToken: rejected) } catch is CloudOAuthSessionError { throw BoxError.reconnect }
            }, classify: classify ?? { body, response, idempotent in Self.classify(body, response, idempotent: idempotent) }, wait: retryWait)
    }
    /// Rate limited (429) and unavailable (503) are sent again; another server error only for reads.
    /// https://developer.box.com/guides/api-calls/permissions-and-errors/rate-limits/
    static func classify(_ body: Data, _ response: HTTPURLResponse, idempotent: Bool) -> CloudHTTPOutcome {
        let error: Error
        do { try check(body, response); return .done } catch let failure { error = failure }
        if [429, 503].contains(response.statusCode) || (idempotent && (500...599).contains(response.statusCode)) { return .retry(error) }
        return .fail(error)
    }
    /// Box's error resource: `{"type": "error", "status": …, "code": …}`.
    /// https://developer.box.com/reference/resources/client-error/
    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = object?["code"] as? String ?? object?["error"] as? String ?? ""
        switch response.statusCode {
        case 401: throw BoxError.reconnect
        case 404: throw BoxError.notFound
        case 409, 412: throw BoxError.conflict
        default: throw BoxError.api(response.statusCode, code)
        }
    }
    func reached(_ error: Error?) {
        lock.withLock { offline = error is URLError && (error as? URLError)?.code != .cancelled }
        onReachability?(error)
    }
    func send(_ request: URLRequest, idempotent: Bool, client: CloudAuthorizedClient? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await (client ?? authorized).send(request, idempotent: idempotent)
            reached(nil); return result
        } catch { reached(error); throw error }
    }
    func get<T: Decodable>(_ url: URL, headers: [String: String] = [:]) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(request(url, headers: headers), idempotent: true).0)
    }

    // MARK: Metadata

    /// The type an ID names, as far as anything read says.
    func kind(of id: String) -> BoxItem.Kind? {
        if id == BoxItem.rootID { return .folder }
        return metadataCache.file(id)?.kind ?? lock.withLock { trashed[id] }
    }
    /// One item. Without a known type it's looked up as a file, then as a folder.
    public func metadata(_ id: String, kind: BoxItem.Kind? = nil) async throws -> BoxItem {
        let id = id.isEmpty ? BoxItem.rootID : id
        guard let kind = kind ?? self.kind(of: id) else {
            do { return try await metadata(id, kind: .file) } catch BoxError.notFound { return try await metadata(id, kind: .folder) }
        }
        let item: BoxItem = try await get(api(itemPath(id, kind), query: [.init(name: "fields", value: Self.fields)]))
        guard item.id == id, item.kind == kind else { throw BoxError.invalidResponse }
        guard !item.isDeleted else { throw BoxError.notFound }
        metadataCache.remember([item]); return item
    }
    /// Whether `item` is a member of the listing `key` (a folder ID; the root is "0").
    func belongs(_ key: String, _ item: BoxItem) -> Bool { !item.isRoot && item.parentID == key }
    struct Page: Decodable {
        var entries: [BoxItem]
        var next: String?
        var total: Int?
        var offset: Int?
        enum CodingKeys: String, CodingKey { case entries; case next = "next_marker"; case total = "total_count"; case offset }
    }
    /// A folder's items, paged by Box's opaque marker. `folderID` "0" is the root.
    public func list(_ folderID: String = BoxItem.rootID, onPage: @Sendable ([BoxItem], Bool) async -> Void = { _, _ in }) async throws -> [BoxItem] {
        let folderID = folderID.isEmpty ? BoxItem.rootID : folderID
        do {
            let read = metadataCache.beginRead()
            defer { withExtendedLifetime(read) {} }
            let since = read.generation
            var files: [String: BoxItem] = [:]
            try await CloudPager.each(repeated: BoxError.invalidResponse) { (marker: String?) in
                var query: [URLQueryItem] = [
                    .init(name: "fields", value: Self.fields), .init(name: "limit", value: "1000"), .init(name: "usemarker", value: "true"),
                ]
                if let marker { query.append(.init(name: "marker", value: marker)) }
                let page: Page = try await get(api(itemPath(folderID, .folder) + "/items", query: query))
                for var item in page.entries where !item.isDeleted {
                    if item.parentID == nil { item.parentID = folderID }
                    files[item.id] = item
                }
                let next = page.next?.isEmpty == false ? page.next : nil
                await onPage(Array(files.values), next == nil)
                return next
            }
            let result = files.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            metadataCache.store(result, key: folderID, since: since)
            onFreshness?(); return result
        } catch {
            if isOffline, let cached = metadataCache.snapshot(folderID) { return cached.files }
            throw error
        }
    }
    public struct SearchPage: Sendable { public var items: [BoxItem]; public var cursor: String? }
    /// Box search, by name only unless `contents`; scoped to a folder's descendants or the whole account. The cursor is
    /// the next offset. https://developer.box.com/reference/get-search/
    public func search(_ query: String, in folderID: String = "", contents: Bool = false, cursor: String? = nil) async throws -> SearchPage {
        let offset = Int(cursor ?? "0") ?? 0
        var items: [URLQueryItem] = [
            .init(name: "query", value: query), .init(name: "fields", value: Self.fields), .init(name: "limit", value: "100"),
            .init(name: "offset", value: String(offset)),
        ]
        if !contents { items.append(.init(name: "content_types", value: "name")) }
        if !folderID.isEmpty, folderID != BoxItem.rootID { items.append(.init(name: "ancestor_folder_ids", value: folderID)) }
        let page: Page = try await get(api("search", query: items))
        let found = page.entries.filter { !$0.isDeleted }
        metadataCache.remember(found)
        let next = offset + page.entries.count
        let more = !page.entries.isEmpty && next < (page.total ?? 0)
        return SearchPage(items: found, cursor: more ? String(next) : nil)
    }
    /// A rendition of at least 256 pixels. Box answers 202 (not made yet) or a redirect to a generic icon when there's
    /// none; neither is a thumbnail. https://developer.box.com/reference/get-files-id-thumbnail-id/
    public func thumbnail(_ item: BoxItem) async throws -> URL {
        guard item.canDownload, let revision = item.revision else { throw BoxError.invalidLocation }
        return try await renditions.file(key: "thumbnail:" + item.id + ":" + revision, name: "thumbnail.jpg") {
            let url = self.api(
                self.itemPath(item.id, .file) + "/thumbnail.jpg",
                query: [.init(name: "min_width", value: "256"), .init(name: "min_height", value: "256")])
            let (data, response) = try await self.send(self.request(url), idempotent: true, client: self.unredirected)
            guard response.statusCode == 200, !data.isEmpty else { throw BoxError.notFound }
            return data
        }
    }
    public struct Quota: Equatable, Sendable { public var used: Int64?; public var total: Int64? }
    public func quota() async throws -> Quota {
        struct Me: Decodable { var space_used: Int64?; var space_amount: Int64? }
        let me: Me = try await get(api("users/me", query: [.init(name: "fields", value: "space_used,space_amount")]))
        // Unlimited plans report 999,999,999,999,999 bytes: no limit.
        return Quota(used: me.space_used, total: me.space_amount.flatMap { $0 > 0 && $0 < 999_999_999_999_999 ? $0 : nil })
    }
    public var contentSource: BoxContentSource {
        lock.withLock {
            if let source { return source }; let new = BoxContentSource(client: self); source = new; return new
        }
    }
    func emit(_ batch: CloudChangeBatch) { lock.withLock { source }?.onChanges?(batch); onFreshness?() }
    func noteTrashed(_ item: BoxItem) { lock.withLock { trashed[item.id] = item.kind } }
}
