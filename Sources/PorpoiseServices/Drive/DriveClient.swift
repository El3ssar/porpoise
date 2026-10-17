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
    public let openCache: CloudOpenCache
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
    public static let changed = Notification.Name("PorpoiseDriveMetadataChanged")
    private var offline = false
    public var isOffline: Bool { lock.withLock { offline } }
    public var canSaveEdits: Bool { baseURL.scheme == "http" && baseURL.host == "127.0.0.1" }
    func setOffline(_ value: Bool) {
        let returned = lock.withLock {
            let returned = offline && !value; offline = value; return returned
        }
        if returned { emitContentChanges(.init(reset: true)) }
    }
    var pollingChanges = false
    var polling: Task<Void, Never>?
    public let mutationJournal: DriveMutationJournal
    let tokens: DriveTokenManager
    let http: DriveHTTP
    let baseURL: URL
    private let report: @Sendable (Error?) -> Void
    let lock = NSLock()
    var cache: [String: DriveFile] = [:]
    static let fields =
        "id,name,mimeType,driveId,resourceKey,size,parents,headRevisionId,version,md5Checksum,appProperties,modifiedTime,thumbnailLink,hasThumbnail,webViewLink,owners(displayName,emailAddress,photoLink),shared,capabilities(canDownload,canListChildren,canEdit,canRename,canTrash,canUntrash,canAddChildren,canMoveItemWithinDrive,canMoveItemOutOfDrive,canCopy),shortcutDetails,exportLinks,trashed,permissions(id,type,role,displayName,emailAddress,photoLink),sharingUser(displayName,emailAddress,photoLink),lastModifyingUser(displayName,emailAddress,photoLink),sharedWithMeTime"

    public init(
        accountID: UUID, tokens: DriveTokenManager, http: DriveHTTP = DriveHTTP(),
        baseURL: URL = URL(string: "https://www.googleapis.com/drive/v3/")!, mutationJournal: DriveMutationJournal = .shared,
        metadataDirectory: URL? = nil, report: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        self.offlineDirectory = metadataDirectory?.appendingPathComponent("Offline")
        self.mediaCache = DriveMediaCache(accountID: accountID, directory: metadataDirectory?.appendingPathComponent("Previews"))
        self.metadataCache = DriveMetadataCache(accountID: accountID, directory: metadataDirectory)
        self.openCache = CloudOpenCache(directory: self.metadataCache.directory.appendingPathComponent("OpenFiles"))
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
        return lock.withLock { cache[id] } ?? metadataCache.file(id)
    }

    func remember(_ files: [DriveFile]) {
        lock.withLock { for file in files { cache[file.id] = file } }
        metadataCache.remember(files)
    }

    func request(_ path: String, query: [URLQueryItem] = [], resource: (String, String?)? = nil) async throws -> Data {
        do {
            for attempt in 0...4 {
                do {
                    let data = try await perform(path, query: query, resource: resource)
                    setOffline(false)
                    return data
                } catch {
                    let retry: Bool
                    switch error as? DriveError {
                    case .quota, .rateLimited: retry = true
                    case .http(let code): retry = (500...599).contains(code)
                    default: retry = false
                    }
                    guard retry, attempt < 4 else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 1_000_000_000))
                }
            }
            throw DriveError.quota
        } catch {
            if let error = error as? URLError, error.code != .cancelled { setOffline(true) }
            report(error); throw error
        }
    }

    private func perform(_ path: String, query: [URLQueryItem], resource: (String, String?)?) async throws -> Data {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 60
        if let (id, key) = resource, let key {
            // Opaque IDs/resource keys must not introduce headers or alter Drive's id/key syntax.
            guard DriveLink.isValidID(id), DriveLink.isValidID(key) else { throw DriveError.invalidLocation }
            request.setValue("\(id)/\(key)", forHTTPHeaderField: "X-Goog-Drive-Resource-Keys")
        }
        let token = try await tokens.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await http.response(request)
        if response.statusCode == 401 {
            let renewed = try await tokens.accessToken(rejectedToken: token)
            request.setValue("Bearer \(renewed)", forHTTPHeaderField: "Authorization")
            (data, response) = try await http.response(request)
        }
        // Drive also reports rate-limit quota as 403. Do not expose provider bodies in errors.
        if response.statusCode == 403,
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
            envelope.error.errors?.contains(where: { ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"].contains($0.reason) })
                == true
        {
            throw DriveError.quota
        }
        if response.statusCode == 403,
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
            envelope.error.errors?.contains(where: { $0.reason == "exportSizeLimitExceeded" }) == true
        {
            throw DriveError.exportTooLarge
        }
        try DriveHTTP.check(response.statusCode)
        report(nil)
        return data
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
        let resourceKey = resourceKey ?? lock.withLock { cache[id]?.resourceKey }
        let data = try await request(
            "files/\(id)",
            query: [
                URLQueryItem(name: "fields", value: Self.fields), URLQueryItem(name: "supportsAllDrives", value: "true"),
            ], resource: (id, resourceKey))
        var file = try decode(DriveFile.self, data)
        file.resourceKey = file.resourceKey ?? resourceKey
        guard (file.id == id || id == "root"), DriveLink.isValidID(file.id), includeTrashed || file.trashed != true else { throw DriveError.notFound }
        remember([file])
        if id == "root" {
            lock.withLock { cache["root"] = file }
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
            remember(files)
            return DrivePage(files: files, nextPageToken: drives.nextPageToken)
        }
        var parentID = "root"
        var driveID: String?
        var resourceKey = location.resourceKey
        var filter: String
        switch location.collection {
        case .sharedWithMe: filter = "sharedWithMe = true and trashed = false"
        case .folder(let id, let drive):
            let known = lock.withLock { cache[id] }
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
        remember(files)
        return DrivePage(files: files, nextPageToken: page.nextPageToken)
    }

    public func list(_ location: DriveLocation) async throws -> [DriveFile] {
        var files: [DriveFile] = []
        var token: String?
        var seen: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let page = try await listPage(location, pageToken: token)
            files += page.files
            token = page.nextPageToken
            if let token, !seen.insert(token).inserted { throw DriveError.invalidResponse }
        } while token != nil
        return files
    }

    public func clearCaches() async {
        stopPolling()
        metadataCache.clear()
        lock.withLock { cache.removeAll() }
        await mediaCache.clear()
        openCache.clear()
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

    public func thumbnail(_ file: DriveFile) async throws -> URL {
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
        return try await mediaCache.file(
            key: "thumbnail|\(target.id)|\(target.headRevisionId ?? target.version ?? target.modifiedTime ?? "")|\(url.absoluteString)",
            name: "thumbnail.jpg"
        ) {
            if self.isOffline { throw DriveError.offline }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(try await self.tokens.accessToken())", forHTTPHeaderField: "Authorization")
            return try await self.http.data(request)
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
