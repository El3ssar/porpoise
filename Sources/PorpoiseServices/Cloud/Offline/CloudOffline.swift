import Foundation

public struct CloudKeepPlan: Equatable, Sendable {
    public var bytes: Int64
    public var items: Int
    public var available: Int64
    public var fits: Bool
    public var needsConfirmation: Bool { bytes >= 1_000_000_000 || items >= 500 }
    public init(bytes: Int64, items: Int, available: Int64, fits: Bool) {
        self.bytes = bytes; self.items = items; self.available = available; self.fits = fits
    }
}

public struct CloudOfflineUsage: Equatable, Sendable {
    public var kept: Int64
    public var recent: Int64
    public init(kept: Int64 = 0, recent: Int64 = 0) { self.kept = kept; self.recent = recent }
}

/// Synchronous snapshot for menus and Properties. All access to the facade is on the main queue.
public struct CloudOfflineDetails: Equatable, Sendable {
    public var downloaded = false
    public var kept = false
    public var inheritedFrom: String?
    public var bytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var items = 0
    public var totalItems = 0
    public var progress: Double?
    public var error: String?
    public var export: String?
    public init() {}
}

/// Provider-neutral, main-queue surface. Notifications carry affected URLs in userInfo["urls"].
/// The facade owns account stores; UI consumers never need a Drive client or filesystem path.
public final class CloudOffline {
    public static let shared = CloudOffline()
    public static let changed = Notification.Name("PorpoiseCloudOfflineChanged")
    public let accounts: CloudAccounts
    public var root: URL
    /// Only recent copies count towards this limit. nil means no limit.
    public var recentLimit: Int64? = 5_000_000_000

    public init(accounts: CloudAccounts = .shared, root: URL? = nil) {
        self.accounts = accounts
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porpoise/Cloud", isDirectory: true)
    }

    public func source(for url: URL) -> CloudContentSource? {
        guard let id = accounts.backend?.accountID(for: url) else { return nil }
        return accounts.backend?.content(for: id)
    }

    public func details(for url: URL) -> CloudOfflineDetails { CloudOfflineDetails() }
    public func state(for url: URL) -> CloudState {
        guard let source = source(for: url), let ref = source.ref(for: url),
            source.cachedItem(ref)?.isFolder != true
        else { return .local }
        return .cloudOnly
    }
    public func usage(account: String) -> CloudOfflineUsage { CloudOfflineUsage() }

    @discardableResult
    public func plan(keep urls: [URL], done: @escaping (Result<CloudKeepPlan, Error>) -> Void) -> () -> Void {
        done(.failure(CloudContentError.unsupported)); return {}
    }
    @discardableResult
    public func downloadNow(_ urls: [URL], done: @escaping (Error?) -> Void = { _ in }) -> () -> Void {
        done(CloudContentError.unsupported); return {}
    }
    @discardableResult
    public func keep(_ on: Bool, _ urls: [URL], done: @escaping (Error?) -> Void = { _ in }) -> () -> Void {
        done(CloudContentError.unsupported); return {}
    }
    /// Refusals are returned immediately; byte removal is queued off the main thread.
    public func removeDownload(_ urls: [URL]) -> [String] { [] }
    public func removeRecent(account: String, done: @escaping (Error?) -> Void = { _ in }) { done(nil) }
    public func wipe(account: String, done: @escaping (Error?) -> Void = { _ in }) { done(nil) }
}
