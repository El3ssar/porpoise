import Foundation

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
    func request(
        _ route: String, arguments: Any, content: Bool = false, body: Data? = nil, range: Range<Int64>? = nil,
        rejectedToken: String? = nil
    ) async throws -> URLRequest {
        var request = URLRequest(url: (content ? configuration.contentURL : configuration.apiURL).appendingPathComponent(route))
        request.httpMethod = "POST"
        let access: String
        do { access = try await tokens.accessToken(rejectedToken: rejectedToken) } catch is CloudOAuthSessionError { throw DropboxError.reconnect }
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
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
            var request = try await request(route, arguments: arguments, content: content, body: body)
            var (data, response) = try await http.response(request)
            if response.statusCode == 401 {
                request = try await self.request(
                    route, arguments: arguments, content: content, body: body,
                    rejectedToken: request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst(7)) })
                (data, response) = try await http.response(request)
            }
            try Self.check(data, response); reached(nil); return data
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
            var cursor: String?; var seen = Set<String>(); var files: [String: DropboxItem] = [:]
            repeat {
                let page = try await listPage(path, cursor: cursor)
                for item in page.entries {
                    if item.tag == "deleted" { files = files.filter { $0.value.pathLower != item.pathLower } } else { files[item.id] = item }
                }
                cursor = page.cursor
                await onPage(Array(files.values), !page.hasMore)
                if !page.hasMore { break }
                guard seen.insert(page.cursor).inserted else { throw DropboxError.invalidResponse }
            } while true
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
        var items: [DropboxItem] = []; var cursor: String?; var seen = Set<String>()
        repeat {
            let page: Files = try await rpc(
                cursor == nil ? "sharing/list_received_files" : "sharing/list_received_files/continue", cursor.map { ["cursor": $0] } ?? [:])
            for entry in page.entries { items.append(try await metadata(entry.id)) }
            cursor = page.cursor
            if let cursor, !seen.insert(cursor).inserted { throw DropboxError.invalidResponse }
        } while cursor != nil
        seen.removeAll()
        repeat {
            let page: Folders = try await rpc(
                cursor == nil ? "sharing/list_folders" : "sharing/list_folders/continue", cursor.map { ["cursor": $0] } ?? [:])
            for folder in page.entries {
                if let path = folder.path_lower {
                    items.append(try await metadata(path))
                } else {
                    items.append(DropboxItem(id: "ns:" + folder.shared_folder_id, name: folder.name, tag: "folder"))
                }
            }
            cursor = page.cursor
            if let cursor, !seen.insert(cursor).inserted { throw DropboxError.invalidResponse }
        } while cursor != nil
        items = Array(Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        metadataCache.store(items, key: "shared"); return items
    }
    public func namespaceClient(_ namespaceID: String) -> DropboxClient {
        let client = DropboxClient(
            accountID: accountID, configuration: configuration, tokens: tokens, namespaceID: namespaceID, directory: directory, http: http)
        client.onReachability = onReachability; client.onFreshness = onFreshness; return client
    }
    public func sharedFolderClient(_ folder: DropboxItem) throws -> DropboxClient {
        guard folder.isFolder, folder.id.hasPrefix("ns:"), folder.id.count > 3 else { throw DropboxError.invalidLocation }
        return namespaceClient(String(folder.id.dropFirst(3)))
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
