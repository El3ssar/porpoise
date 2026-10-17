import Foundation

public struct CloudItemRef: Hashable, Codable, Sendable {
    public var account: String
    public var item: String
    public init(account: String, item: String) { self.account = account; self.item = item }
}

public enum CloudChecksum: Hashable, Codable, Sendable {
    case md5(String), sha256(String), dropbox(String), quickXor(String)
}

public struct CloudRemoteItem: Codable, Sendable, Equatable {
    public var ref: CloudItemRef
    public var name: String
    public var parents: [String]
    public var isFolder: Bool
    public var size: Int64?
    public var revision: String?
    public var checksum: CloudChecksum?
    public var export: String?
    public var canDownload: Bool

    public init(
        ref: CloudItemRef, name: String, parents: [String] = [], isFolder: Bool = false,
        size: Int64? = nil, revision: String? = nil, checksum: CloudChecksum? = nil,
        export: String? = nil, canDownload: Bool = true
    ) {
        self.ref = ref; self.name = name; self.parents = parents; self.isFolder = isFolder
        self.size = size; self.revision = revision; self.checksum = checksum
        self.export = export; self.canDownload = canDownload
    }
}

public struct CloudChangeBatch: Sendable {
    public var changed: [CloudRemoteItem]
    public var removed: [String]
    public var reset: Bool
    public init(changed: [CloudRemoteItem] = [], removed: [String] = [], reset: Bool = false) {
        self.changed = changed; self.removed = removed; self.reset = reset
    }
}

public enum CloudContentError: Error, Equatable, LocalizedError {
    case unsupported, offline, notFound, changed, checksum, lowSpace, heldForEditing, unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Offline copies aren’t available for this item."
        case .notFound: return "This file is no longer in the cloud."
        case .offline: return "This file opens when you’re back online."
        case .changed: return "The file changed while it was downloading. Try again."
        case .checksum: return "The downloaded copy failed its integrity check."
        case .lowSpace: return "Paused: not enough space on this Mac."
        case .heldForEditing: return "This file has an open edit session or changes not in the cloud yet."
        case .unavailable(let reason): return reason
        }
    }
}

public protocol CloudContentSource: AnyObject, Sendable {
    var accountID: String { get }
    var providerTitle: String { get }
    /// Optional private directory for injected/test accounts; nil uses the app-wide offline root.
    var offlineDirectory: URL? { get }
    /// An edit session or unsent edit holds these bytes against automatic removal.
    func holdsCopy(_ ref: CloudItemRef) async -> Bool
    func ref(for url: URL) -> CloudItemRef?
    func url(for item: CloudRemoteItem) -> URL
    func cachedItem(_ ref: CloudItemRef) -> CloudRemoteItem?
    func item(_ ref: CloudItemRef) async throws -> CloudRemoteItem
    func children(_ folder: CloudItemRef) async throws -> [CloudRemoteItem]
    func download(
        _ item: CloudRemoteItem, to partial: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
    func download(
        _ item: CloudRemoteItem, to partial: URL,
        checkpoint: @escaping @Sendable () async throws -> Void,
        progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
    var isOffline: Bool { get }
    var onChanges: (@Sendable (CloudChangeBatch) -> Void)? { get set }
}

extension CloudContentSource {
    public func download(
        _ item: CloudRemoteItem, to partial: URL,
        checkpoint: @escaping @Sendable () async throws -> Void,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        try await checkpoint(); try await download(item, to: partial, progress: progress); try await checkpoint()
    }
    public var offlineDirectory: URL? { nil }
    public func holdsCopy(_ ref: CloudItemRef) async -> Bool { false }
}
