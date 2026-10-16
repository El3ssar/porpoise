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
    private let tokens: DriveTokenManager
    private let http: DriveHTTP
    private let baseURL: URL
    private let report: @Sendable (Error?) -> Void
    private let lock = NSLock()
    private var cache: [String: DriveFile] = [:]
    static let fields =
        "id,name,mimeType,driveId,resourceKey,size,modifiedTime,webViewLink,owners(displayName,emailAddress,photoLink),shared,capabilities(canDownload,canListChildren),shortcutDetails,exportLinks,trashed,permissions(id,type,role,displayName,emailAddress,photoLink),sharingUser(displayName,emailAddress,photoLink),lastModifyingUser(displayName,emailAddress,photoLink)"

    public init(
        accountID: UUID, tokens: DriveTokenManager, http: DriveHTTP = DriveHTTP(),
        baseURL: URL = URL(string: "https://www.googleapis.com/drive/v3/")!, report: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
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
        return lock.withLock { cache[id] }
    }

    private func remember(_ files: [DriveFile]) {
        lock.withLock { for file in files { cache[file.id] = file } }
    }

    private func request(_ path: String, query: [URLQueryItem] = [], resource: (String, String?)? = nil) async throws -> Data {
        do { return try await perform(path, query: query, resource: resource) } catch { report(error); throw error }
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

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let result = try? JSONDecoder().decode(type, from: data) else { throw DriveError.invalidResponse }
        return result
    }

    public func file(_ id: String, resourceKey: String? = nil) async throws -> DriveFile {
        guard DriveLink.isValidID(id) else { throw DriveError.invalidLocation }
        let data = try await request(
            "files/\(id)",
            query: [
                URLQueryItem(name: "fields", value: Self.fields), URLQueryItem(name: "supportsAllDrives", value: "true"),
            ], resource: (id, resourceKey))
        var file = try decode(DriveFile.self, data)
        file.resourceKey = file.resourceKey ?? resourceKey
        guard file.id == id, file.trashed != true else { throw DriveError.notFound }
        remember([file])
        return file
    }

    public func resolve(_ file: DriveFile) async throws -> DriveFile {
        var current = file
        var seen: Set<String> = []
        while current.isShortcut {
            try Task.checkCancellation()
            guard seen.count < 16, seen.insert(current.id).inserted else { throw DriveError.shortcutCycle }
            guard let shortcut = current.shortcutDetails else { throw DriveError.invalidResponse }
            current = try await self.file(shortcut.targetId, resourceKey: shortcut.targetResourceKey)
        }
        return current
    }

    public func listPage(_ location: DriveLocation, pageToken: String? = nil) async throws -> DrivePage {
        guard location.accountID == accountID else { throw DriveError.invalidLocation }
        var query = [URLQueryItem(name: "pageSize", value: "200")]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        if case .sharedDrives = location.collection {
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
            let target = try await resolve(file(id, resourceKey: resourceKey))
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
