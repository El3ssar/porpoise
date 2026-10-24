import Foundation
import PorpoiseCore

public struct DriveAccountInfo: Sendable {
    public let storageUsed: Int64?
    public let storageLimit: Int64?
    public let hasSharedDrives: Bool
}

public struct DrivePage: Sendable {
    public var files: [DriveFile]
    public var nextPageToken: String?
}

/// Native Drive v3 read-only API. Each page can be consumed independently; cancellation propagates to HTTP.
public final class DriveClient: @unchecked Sendable {
    public let accountID: UUID
    public let mediaCache: DriveMediaCache
    public let metadataCache: DriveMetadataCache
    var offlineSource: DriveContentSource?
    let offlineDirectory: URL?
    private var editStore: DriveEditStore?
    public var edits: DriveEditStore {
        lock.withLock {
            if let editStore { return editStore }
            let store = DriveEditStore(client: self)
            editStore = store
            return store
        }
    }
    private var offline = false
    public var isOffline: Bool { lock.withLock { offline } }
    func setOffline(_ value: Bool) {
        let returned = lock.withLock {
            let returned = offline && !value; offline = value; return returned
        }
        if returned { emitContentChanges(.init(reset: true)) }
    }
    var changeFeed: CloudChangeFeed?
    var pollingGeneration = 0
    public var changes: CloudChangeFeed {
        lock.withLock {
            if let changeFeed { return changeFeed }
            let feed = CloudChangeFeed(client: self); changeFeed = feed; return feed
        }
    }
    public let mutationJournal: DriveMutationJournal
    let tokens: DriveTokenManager
    let http: DriveHTTP
    let baseURL: URL
    /// How the pause before a retry is spent (`CloudAuthorizedClient.defaultWait`; tests record it instead).
    let retryWait: @Sendable (TimeInterval) async throws -> Void
    private let report: @Sendable (Error?) -> Void
    let lock = NSLock()
    static let fields =
        "id,name,mimeType,driveId,resourceKey,size,parents,headRevisionId,version,md5Checksum,appProperties,modifiedTime,thumbnailLink,hasThumbnail,webViewLink,owners(displayName,emailAddress,photoLink),shared,capabilities(canDownload,canListChildren,canEdit,canRename,canTrash,canUntrash,canAddChildren,canMoveItemWithinDrive,canMoveItemOutOfDrive,canCopy),shortcutDetails,exportLinks,trashed,permissions(id,type,role,displayName,emailAddress,photoLink),sharingUser(displayName,emailAddress,photoLink),lastModifyingUser(displayName,emailAddress,photoLink),sharedWithMeTime"

    public init(
        accountID: UUID, tokens: DriveTokenManager, http: DriveHTTP = DriveHTTP(),
        baseURL: URL = URL(string: "https://www.googleapis.com/drive/v3/")!, mutationJournal: DriveMutationJournal = .shared,
        metadataDirectory: URL? = nil, report: @escaping @Sendable (Error?) -> Void = { _ in },
        retryWait: @escaping @Sendable (TimeInterval) async throws -> Void = CloudAuthorizedClient.defaultWait
    ) {
        self.retryWait = retryWait
        self.offlineDirectory = metadataDirectory?.appendingPathComponent("Offline")
        self.mediaCache = DriveMediaCache(accountID: accountID, directory: metadataDirectory?.appendingPathComponent("Previews"))
        self.metadataCache = DriveMetadataCache(accountID: accountID, directory: metadataDirectory)
        self.mutationJournal = mutationJournal
        self.accountID = accountID; self.tokens = tokens; self.http = http; self.baseURL = baseURL; self.report = report
    }

    public func accountInfo() async throws -> DriveAccountInfo {
        struct About: Decodable {
            struct Quota: Decodable { let usage: String?; let limit: String? }
            let storageQuota: Quota?
        }
        let about = try decode(About.self, await request("about", query: [URLQueryItem(name: "fields", value: "storageQuota")]))
        let drives = try await listPage(DriveLocation(accountID: accountID, collection: .sharedDrives))
        return DriveAccountInfo(
            storageUsed: about.storageQuota?.usage.flatMap(Int64.init), storageLimit: about.storageQuota?.limit.flatMap(Int64.init),
            hasSharedDrives: !drives.files.isEmpty)
    }

    public func cachedFile(for url: URL) -> DriveFile? {
        guard let location = DriveLocation(url: url), location.accountID == accountID,
            case .folder(let id, _) = location.collection
        else { return nil }
        return metadataCache.file(id)
    }

    /// The file with `id` as last read ("root": My Drive's own folder), without asking Drive.
    func cachedFile(id: String) -> DriveFile? { metadataCache.file(id) }

    /// What a change made here returned: newer than anything read before it.
    func remember(_ files: [DriveFile]) {
        metadataCache.remember(files)
    }

    /// What a request started at `since` (the metadata cache's generation) read: a change made here meanwhile is newer,
    /// and is what's kept and returned (a listing that started before a rename landing after it showed the old name).
    func learned(_ files: [DriveFile], since: UInt64) -> [DriveFile] {
        metadataCache.learn(files, since: since)
    }

    func request(_ path: String, query: [URLQueryItem] = [], resource: (String, String?)? = nil) async throws -> Data {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 60
        if let (id, key) = resource, let key {
            // Opaque IDs/resource keys must not introduce headers or alter Drive's id/key syntax.
            guard DriveLink.isValidID(id), DriveLink.isValidID(key) else { throw DriveError.invalidLocation }
            request.setValue("\(id)/\(key)", forHTTPHeaderField: "X-Goog-Drive-Resource-Keys")
        }
        return try await read(request)
    }

    /// A read (always safe to send again): offline and reachability are told either way.
    func read(_ request: URLRequest) async throws -> Data {
        do {
            let (data, _) = try await authorized(mutation: false).send(request, idempotent: true)
            setOffline(false); report(nil)
            return data
        } catch {
            if let error = error as? URLError, error.code != .cancelled { setOffline(true) }
            report(error); throw error
        }
    }

    /// Drive's requests with the account's token. Changes name more refusals than reads (no write access, storage full).
    func authorized(mutation: Bool) -> CloudAuthorizedClient {
        CloudAuthorizedClient(
            transport: http.transport, token: { [tokens] rejected in try await tokens.accessToken(rejectedToken: rejected) },
            classify: { body, response, idempotent in Self.classify(body, response, idempotent: idempotent, mutation: mutation) },
            wait: retryWait)
    }

    /// Busy (429, or a rate limit given as 403) is sent again; a server error only when that can't do anything twice.
    static func classify(_ body: Data, _ response: HTTPURLResponse, idempotent: Bool, mutation: Bool) -> CloudHTTPOutcome {
        let status = response.statusCode
        if (200..<300).contains(status) || (mutation && status == 308) { return .done }
        // Do not expose provider bodies in errors: only Drive's reasons are read (listed in its error, or named in the text).
        let listed = Set((try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error.errors?.map(\.reason) ?? [])
        let text = String(decoding: body.prefix(65536), as: UTF8.self)
        func says(_ reason: String) -> Bool { listed.contains(reason) || text.contains(reason) }
        let rateLimited = says("rateLimitExceeded") || says("RateLimitExceeded") || says("dailyLimitExceeded")
        if status == 429 || (status == 403 && rateLimited) { return .retry(DriveError.quota) }
        if status == 403, says("exportSizeLimitExceeded") { return .fail(DriveError.exportTooLarge) }
        if status == 403, mutation, says("insufficientPermissions") { return .fail(DriveError.needsWriteAccess) }
        if status == 403, mutation, says("storageQuotaExceeded") { return .fail(DriveError.quota) }
        if (500...599).contains(status) { return idempotent ? .retry(DriveError.http(status)) : .fail(DriveError.http(status)) }
        do { try DriveHTTP.check(status); return .done } catch { return .fail(error) }
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            struct Reason: Decodable { let reason: String }
            let errors: [Reason]?
        }
        let error: APIError
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let result = try? JSONDecoder().decode(type, from: data) else { throw DriveError.invalidResponse }
        return result
    }

    public func file(_ id: String, resourceKey: String? = nil, includeTrashed: Bool = false) async throws -> DriveFile {
        guard DriveLink.isValidID(id) else { throw DriveError.invalidLocation }
        let resourceKey = resourceKey ?? metadataCache.file(id)?.resourceKey
        let since = metadataCache.generation
        let data = try await request(
            "files/\(id)",
            query: [
                URLQueryItem(name: "fields", value: Self.fields), URLQueryItem(name: "supportsAllDrives", value: "true"),
            ], resource: (id, resourceKey))
        var file = try decode(DriveFile.self, data)
        file.resourceKey = file.resourceKey ?? resourceKey
        guard (file.id == id || id == "root"), DriveLink.isValidID(file.id), includeTrashed || file.trashed != true else { throw DriveError.notFound }
        file = learned([file], since: since)[0]
        if id == "root" {
            metadataCache.rememberRoot(file)
        }
        return file
    }

    public func resolve(_ file: DriveFile) async throws -> DriveFile {
        var current = file
        var seen: Set<String> = []
        while current.isShortcut {
            try Task.checkCancellation()
            guard seen.count < 16, seen.insert(current.id).inserted else { throw DriveError.shortcutCycle }
            guard let shortcut = current.shortcutDetails else { throw DriveError.invalidResponse }
            if isOffline {
                guard let cached = metadataCache.file(shortcut.targetId) else { throw DriveError.offline }
                current = cached
            } else {
                current = try await self.file(shortcut.targetId, resourceKey: shortcut.targetResourceKey)
            }
        }
        return current
    }

    public func listPage(_ location: DriveLocation, pageToken: String? = nil) async throws -> DrivePage {
        guard location.accountID == accountID else { throw DriveError.invalidLocation }
        let since = metadataCache.generation
        var query = [URLQueryItem(name: "pageSize", value: "1000")]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        if case .sharedDrives = location.collection {
            query[0] = URLQueryItem(name: "pageSize", value: "100")
            query.append(URLQueryItem(name: "fields", value: "nextPageToken,drives(id,name)"))
            struct Drives: Decodable {
                struct Drive: Decodable { let id: String; let name: String }
                let drives: [Drive]?
                let nextPageToken: String?
            }
            let drives = try decode(Drives.self, await request("drives", query: query))
            guard (drives.drives ?? []).allSatisfy({ DriveLink.isValidID($0.id) }) else { throw DriveError.invalidResponse }
            let files = (drives.drives ?? []).map {
                DriveFile(id: $0.id, name: $0.name, mimeType: "application/vnd.google-apps.folder", driveId: $0.id)
            }
            return DrivePage(files: learned(files, since: since), nextPageToken: drives.nextPageToken)
        }
        var parentID = "root"
        var driveID: String?
        var resourceKey = location.resourceKey
        var filter: String
        switch location.collection {
        case .sharedWithMe: filter = "sharedWithMe = true and trashed = false"
        case .folder(let id, let drive):
            let known = metadataCache.storage.recentFile(id)
            let source: DriveFile
            if let known { source = known } else { source = try await file(id, resourceKey: resourceKey) }
            let target = try await resolve(source)
            guard target.isFolder, target.operations.canBrowse else { throw DriveError.permissionDenied }
            parentID = target.id; driveID = target.driveId ?? drive; resourceKey = target.resourceKey ?? resourceKey
            filter = "'\(parentID)' in parents and trashed = false"
        default: filter = "'root' in parents and trashed = false"
        }
        query += [
            URLQueryItem(name: "q", value: filter), URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(\(Self.fields))"),
            URLQueryItem(name: "supportsAllDrives", value: "true"), URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "corpora", value: driveID == nil ? "user" : "drive"),
        ]
        if let driveID { query.append(URLQueryItem(name: "driveId", value: driveID)) }
        struct Files: Decodable { let files: [DriveFile]?; let nextPageToken: String?; let incompleteSearch: Bool? }
        let page = try decode(Files.self, await request("files", query: query, resource: (parentID, resourceKey)))
        guard page.incompleteSearch != true else { throw DriveError.invalidResponse }
        let files = page.files ?? []
        guard files.allSatisfy({ DriveLink.isValidID($0.id) }) else { throw DriveError.invalidResponse }
        return DrivePage(files: learned(files, since: since), nextPageToken: page.nextPageToken)
    }

    public func list(_ location: DriveLocation) async throws -> [DriveFile] {
        var files: [DriveFile] = []
        try await CloudPager.each(repeated: DriveError.invalidResponse) { (token: String?) in
            let page = try await listPage(location, pageToken: token)
            files += page.files
            return page.nextPageToken
        }
        return files
    }

    public func clearCaches() async {
        stopPolling()
        let feed = lock.withLock { changeFeed }
        await feed?.stop()
        metadataCache.clear()
        await mediaCache.clear()
    }

    public func preview(_ file: DriveFile, context: DriveTransferContext = .init()) async throws -> URL {
        let target = try await resolve(file)
        if !target.isGoogleDocument {
            let store = try await offlineCopies()
            let item = contentSource.remoteItem(target)
            if let local = try await store.localCopy(item.ref, revision: item.revision) { return local }
            if isOffline { throw DriveError.offline }
            do {
                return try await store.fetch(contentSource.remoteItem(target), progress: { bytes, total in context.progress(bytes, total ?? bytes) })
            } catch CloudContentError.offline { throw DriveError.offline }
        }
        let name = previewName(file: file, target: target)
        if let cached = try await cachedPreview(target) { return cached }
        if isOffline { throw DriveError.offline }
        let epoch = await mediaCache.epoch()
        let staged = try await downloadToStaging(target, preset: .pdf, context: context)
        defer { try? FileManager.default.removeItem(at: staged.url) }
        // The listing may have been old when the download began. Index the verified revision, never that old key.
        let verifiedKey = previewKey(staged.file)
        return try await mediaCache.importFile(staged.url, key: verifiedKey, name: name, epoch: epoch)
    }

    public func cachedPreview(_ file: DriveFile) async throws -> URL? {
        if !file.isGoogleDocument {
            let store = try await offlineCopies()
            return try await store.localCopy(contentSource.remoteItem(file).ref, revision: file.headRevisionId ?? file.version)
        }
        return try await mediaCache.cachedFile(key: previewKey(file), name: previewName(file: file, target: file))
    }

    private func previewKey(_ file: DriveFile) -> String {
        "preview|\(file.id)|\(file.headRevisionId ?? file.version ?? file.modifiedTime ?? "")"
    }

    private func previewName(file: DriveFile, target: DriveFile) -> String {
        let format = target.isGoogleDocument ? DriveExportPreset.pdf.format(for: target.mimeType) : nil
        return format.map { "\(file.name).\($0.fileExtension)" } ?? file.name
    }

    public func thumbnail(_ file: DriveFile, maximumPixelSize: Int? = nil) async throws -> URL {
        let target = try await resolve(file)
        guard target.hasThumbnail != false, let url = target.thumbnailLink, let host = url.host?.lowercased() else {
            // Native Docs/Sheets/Slides can always use a PDF export when no thumbnail is available.
            return try await preview(file)
        }
        let fixture =
            baseURL.scheme == "http" && baseURL.host == "127.0.0.1" && url.scheme == baseURL.scheme
            && url.host == baseURL.host && url.port == baseURL.port
        let google =
            url.scheme == "https" && (host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".googleapis.com") || host == "lh3.google.com")
        guard url.user == nil, url.password == nil, fixture || google else { throw DriveError.invalidResponse }
        let thumbnailURL: URL
        if let maximumPixelSize {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var path = components.percentEncodedPath
            if let suffix = path.range(of: "=s[0-9]+(?:-[A-Za-z0-9]+)*$", options: .regularExpression) { path.removeSubrange(suffix) }
            components.percentEncodedPath = path + "=s\(min(1600, max(64, maximumPixelSize)))"
            guard let sized = components.url else { throw DriveError.invalidResponse }
            thumbnailURL = sized
        } else {
            thumbnailURL = url
        }
        return try await mediaCache.file(
            key: "thumbnail|\(target.id)|\(target.headRevisionId ?? target.version ?? target.modifiedTime ?? "")|\(thumbnailURL.absoluteString)",
            name: "thumbnail.jpg"
        ) {
            if self.isOffline { throw DriveError.offline }
            return try await self.read(URLRequest(url: thumbnailURL))
        }
    }

    public func download(_ file: DriveFile, preset: DriveExportPreset = .office) async throws -> (data: Data, name: String) {
        let target = try await resolve(file)
        guard !target.isFolder, target.capabilities?.canDownload != false else { throw DriveError.permissionDenied }
        if target.isGoogleDocument {
            guard let format = preset.format(for: target.mimeType),
                target.exportLinks == nil || target.exportLinks?[format.mimeType] != nil
            else { throw DriveError.unsupportedExport }
            let data = try await request(
                "files/\(target.id)/export", query: [URLQueryItem(name: "mimeType", value: format.mimeType)],
                resource: (target.id, target.resourceKey))
            return (data, "\(file.name).\(format.fileExtension)")
        }
        guard target.operations.canDownload else { throw DriveError.permissionDenied }
        let data = try await request(
            "files/\(target.id)", query: [URLQueryItem(name: "alt", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")],
            resource: (target.id, target.resourceKey))
        return (data, file.name)
    }
}
