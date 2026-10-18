import Foundation
import PorpoiseCore

/// Dropbox wire policy only. Cache, credentials, bounded streaming and range persistence are shared services.
public final class DropboxClient: @unchecked Sendable {
    public let accountID: UUID
    public let configuration: DropboxConfiguration
    public let tokens: CloudOAuthSession
    public let http: CloudHTTPTransport
    public let namespaceID: String?
    public let metadataCache: CloudMetadataCache<DropboxItem>
    public let journal: CloudJournal<DropboxOperation>
    public let renditions: CloudRenditionCache
    public let directory: URL
    private let lock = NSLock()
    private var offline = false
    private var source: DropboxContentSource?
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
    private var feed: DropboxChangeFeed?
    private var editStore: DropboxEditStore?
    public var changes: DropboxChangeFeed {
        lock.withLock {
            if let feed { return feed }; let new = DropboxChangeFeed(client: self); feed = new; return new
        }
    }
    public var edits: DropboxEditStore {
        lock.withLock {
            if let editStore { return editStore }; let new = DropboxEditStore(client: self); editStore = new; return new
        }
    }
    public init(
        accountID: UUID, configuration: DropboxConfiguration, tokens: CloudOAuthSession,
        namespaceID: String? = nil, directory: URL, http: CloudHTTPTransport = .init()
    ) {
        self.accountID = accountID; self.configuration = configuration; self.tokens = tokens; self.namespaceID = namespaceID
        self.directory = directory; self.http = http
        let scoped = directory.appendingPathComponent(cloudObjectKey(namespaceID ?? "home"))
        metadataCache = CloudMetadataCache(directory: scoped.appendingPathComponent("Metadata"))
        journal = CloudJournal(folder: scoped.appendingPathComponent("Operations"))
        renditions = CloudRenditionCache(directory: scoped.appendingPathComponent("Renditions"))
    }
    func request(_ route: String, arguments: Any, content: Bool = false, body: Data? = nil, range: Range<Int64>? = nil) throws -> URLRequest {
        var request = URLRequest(url: (content ? configuration.contentURL : configuration.apiURL).appendingPathComponent(route))
        request.httpMethod = "POST"
        if let namespaceID, !route.hasPrefix("users/") {
            request.setValue(try dropboxHeader([".tag": "namespace_id", "namespace_id": namespaceID]), forHTTPHeaderField: "Dropbox-API-Path-Root")
        }
        if content {
            request.setValue(try dropboxHeader(arguments), forHTTPHeaderField: "Dropbox-API-Arg")
            // Content-download endpoints have no body. An explicit body selects content-upload format.
            if let body { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type"); request.httpBody = body }
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed])
        }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        return request
    }
    /// Dropbox's requests with the account's token.
    var authorized: CloudAuthorizedClient {
        CloudAuthorizedClient(
            transport: http,
            token: { [tokens] rejected in
                do { return try await tokens.accessToken(rejectedToken: rejected) } catch is CloudOAuthSessionError { throw DropboxError.reconnect }
            }, classify: { body, response, idempotent in Self.classify(body, response, idempotent: idempotent) })
    }
    /// Busy (429) is sent again; a server error only for reads, which can't do anything twice.
    static func classify(_ body: Data, _ response: HTTPURLResponse, idempotent: Bool) -> CloudHTTPOutcome {
        let error: Error
        do { try check(body, response); return .done } catch let failure { error = failure }
        if response.statusCode == 429 || (idempotent && (500...599).contains(response.statusCode)) { return .retry(error) }
        return .fail(error)
    }
    /// Routes that only read: sending one again changes nothing.
    static func reads(_ route: String) -> Bool {
        route.hasPrefix("files/list_folder") || route.hasPrefix("files/search") || route.hasPrefix("sharing/list_") || route.hasPrefix("users/")
            || ["files/get_metadata", "files/download", "files/get_thumbnail_v2", "sharing/get_shared_link_metadata"].contains(route)
    }
    func reached(_ error: Error?) {
        lock.withLock { offline = error is URLError && (error as? URLError)?.code != .cancelled }
        onReachability?(error)
    }
    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        if response.statusCode == 401 { throw DropboxError.reconnect }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        func offset(_ value: Any?) -> Int64? {
            guard let dict = value as? [String: Any] else { return nil }
            if let correct = dict["correct_offset"] as? NSNumber { return correct.int64Value }
            for value in dict.values { if let n = offset(value) { return n } }; return nil
        }
        if let n = offset(object?["error"]) { throw DropboxError.offset(n) }
        let summary = object?["error_summary"] as? String ?? ""
        if summary.contains("not_found") { throw DropboxError.notFound }
        if summary.contains("conflict") { throw DropboxError.conflict }
        throw DropboxError.api(response.statusCode, summary)
    }
    func data(_ route: String, arguments: Any, content: Bool = false, body: Data? = nil) async throws -> Data {
        do {
            let request = try request(route, arguments: arguments, content: content, body: body)
            let (data, _) = try await authorized.send(request, idempotent: Self.reads(route))
            reached(nil); return data
        } catch { reached(error); throw error }
    }
    func rpc<T: Decodable>(_ route: String, _ arguments: Any) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(route, arguments: arguments))
    }
    public func metadata(_ path: String, includeDeleted: Bool = false) async throws -> DropboxItem {
        let item: DropboxItem = try await rpc("files/get_metadata", ["path": path, "include_deleted": includeDeleted])
        if item.tag != "deleted" { metadataCache.remember([item]) }
        return item
    }
    /// Cached folders' IDs by lowercased path (the first, if two share one), rebuilt when the cache changes.
    var folderIDs: [String: String] {
        metadataCache.derived("folderIDs") { files in
            var ids: [String: String] = [:]
            for file in files.values where file.isFolder {
                if let path = file.pathLower, ids[path] == nil { ids[path] = file.id }
            }
            return ids
        }
    }
    public func listPage(_ path: String = "", cursor: String? = nil, recursive: Bool = false) async throws -> DropboxPage {
        let page: DropboxPage
        if let cursor {
            page = try await rpc("files/list_folder/continue", ["cursor": cursor])
        } else {
            page = try await rpc("files/list_folder", ["path": path, "recursive": recursive, "include_deleted": true, "limit": 2000])
        }
        guard !page.cursor.isEmpty else { throw DropboxError.invalidResponse }
        return page
    }
    public func list(_ path: String = "", onPage: @Sendable ([DropboxItem], Bool) async -> Void = { _, _ in }) async throws -> [DropboxItem] {
        do {
            let since = metadataCache.generation
            var cursor: String?; var files: [String: DropboxItem] = [:]
            // IDs by path: a deleted entry names a path, not an ID.
            var paths: [String?: Set<String>] = [:]
            try await CloudPager.each(repeated: DropboxError.invalidResponse) { (next: String?) in
                let page = try await listPage(path, cursor: next)
                for item in page.entries {
                    if item.tag == "deleted" {
                        for id in paths.removeValue(forKey: item.pathLower) ?? [] { files[id] = nil }
                    } else {
                        if let old = files[item.id] { paths[old.pathLower]?.remove(item.id) }
                        files[item.id] = item; paths[item.pathLower, default: []].insert(item.id)
                    }
                }
                cursor = page.cursor
                await onPage(Array(files.values), !page.hasMore)
                return page.hasMore ? page.cursor : nil
            }
            let result = files.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            metadataCache.store(result, key: path, since: since)
            // Nonrecursive listing cursors are kept separately from the whole-account change cursor.
            metadataCache.setCursor(cursor, scope: "listing:" + path)
            onFreshness?(); return result
        } catch {
            if isOffline, let cached = metadataCache.snapshot(path) { return cached.files }
            throw error
        }
    }
    public struct SearchPage: Sendable { public var items: [DropboxItem]; public var cursor: String? }
    public func search(_ query: String, path: String = "", contents: Bool = true, cursor: String? = nil) async throws -> SearchPage {
        struct Match: Decodable { struct Wrapped: Decodable { var metadata: DropboxItem }; var metadata: Wrapped }
        struct Result: Decodable { var matches: [Match]; var cursor: String?; var has_more: Bool }
        let result: Result
        if let cursor {
            result = try await rpc("files/search/continue_v2", ["cursor": cursor])
        } else {
            result = try await rpc("files/search_v2", ["query": query, "options": ["path": path, "filename_only": !contents, "max_results": 100]])
        }
        guard !result.has_more || result.cursor?.isEmpty == false else { throw DropboxError.invalidResponse }
        let items = result.matches.map { $0.metadata.metadata }; metadataCache.remember(items)
        return SearchPage(items: items, cursor: result.has_more ? result.cursor : nil)
    }
    public func sharedWithMe() async throws -> [DropboxItem] {
        struct Received: Decodable { var id: String; var name: String }
        struct Folder: Decodable { var shared_folder_id: String; var name: String; var path_lower: String? }
        struct Files: Decodable { var entries: [Received]; var cursor: String? }
        struct Folders: Decodable { var entries: [Folder]; var cursor: String? }
        var items: [DropboxItem] = []
        try await CloudPager.each(repeated: DropboxError.invalidResponse) { (cursor: String?) in
            let page: Files = try await rpc(
                cursor == nil ? "sharing/list_received_files" : "sharing/list_received_files/continue", cursor.map { ["cursor": $0] } ?? [:])
            for entry in page.entries { items.append(try await metadata(entry.id)) }
            return page.cursor
        }
        try await CloudPager.each(repeated: DropboxError.invalidResponse) { (cursor: String?) in
            let page: Folders = try await rpc(
                cursor == nil ? "sharing/list_folders" : "sharing/list_folders/continue", cursor.map { ["cursor": $0] } ?? [:])
            for folder in page.entries {
                if let path = folder.path_lower {
                    items.append(try await metadata(path))
                } else {
                    items.append(DropboxItem(id: "ns:" + folder.shared_folder_id, name: folder.name, tag: "folder"))
                }
            }
            return page.cursor
        }
        items = Array(Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        metadataCache.store(items, key: "shared"); return items
    }
    public func namespaceClient(_ namespaceID: String) -> DropboxClient {
        let client = DropboxClient(
            accountID: accountID, configuration: configuration, tokens: tokens, namespaceID: namespaceID, directory: directory, http: http)
        client.onReachability = onReachability; client.onFreshness = onFreshness; return client
    }
    public func thumbnail(_ item: DropboxItem) async throws -> URL {
        guard !item.isFolder, let rev = item.rev else { throw DropboxError.invalidLocation }
        return try await renditions.file(key: "thumbnail:" + item.id + ":" + rev, name: "thumbnail.jpg") {
            try await self.data(
                "files/get_thumbnail_v2",
                arguments: [
                    "resource": [".tag": "path", "path": "rev:" + rev],
                    "format": "jpeg", "size": "w256h256", "mode": "strict",
                ], content: true)
        }
    }
    public var contentSource: DropboxContentSource {
        lock.withLock {
            if let source { return source }; let new = DropboxContentSource(client: self); source = new; return new
        }
    }
    func emit(_ batch: CloudChangeBatch) { lock.withLock { source }?.onChanges?(batch); onFreshness?() }
}
