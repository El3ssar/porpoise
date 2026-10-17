import Foundation

/// Why an item is kept downloaded.
public enum CloudKeep: Equatable, Sendable {
    case no
    /// The user chose Keep Downloaded on the item itself.
    case direct
    /// A folder above it is kept (its name, for "Kept because “Photos” is kept downloaded.").
    case inherited(String)

    public init(_ d: CloudOfflineDetails) {
        if let folder = d.inheritedFrom {
            self = .inherited(folder)
        } else {
            self = d.kept ? .direct : .no
        }
    }
}

/// Offline copies of cloud accounts' items, as the screens use them: the engine (`CloudOffline`) and the demo one in
/// test instances implement it. Main queue; URLs are account locations (never `file://`).
public protocol CloudOfflineService: AnyObject {
    /// The item can have an offline copy (false for virtual rows such as Shared with me: the commands are hidden).
    func supports(_ url: URL) -> Bool
    /// The badge state, from memory.
    func state(for url: URL) -> CloudState
    /// Why the item can't be downloaded (the owner turned it off…); nil when it can. The commands show disabled.
    func keepDenial(for url: URL) -> String?
    /// What is on this Mac, from memory (menus, Properties).
    func details(for url: URL) -> CloudOfflineDetails

    func downloadNow(_ urls: [URL])
    /// Counts what keeping `urls` takes (folders recursively); returns a cancel function.
    func plan(keep urls: [URL], done: @escaping (Result<CloudKeepPlan, Error>) -> Void) -> () -> Void
    func keep(_ urls: [URL])
    /// The copies stay as recent downloads (they may be removed to save space).
    func stopKeeping(_ urls: [URL])
    /// Unpins and deletes the copies; returns a message for each item skipped (unsent edits…).
    func removeDownload(_ urls: [URL]) -> [String]

    func usage(account: String) -> CloudOfflineUsage
    func removeRecent(account: String)
    /// Bytes recent downloads may use (nil: no limit).
    var cacheLimit: Int64? { get set }
    /// Where offline copies are kept.
    var root: URL { get }
}

extension CloudOfflineService {
    public func keep(for url: URL) -> CloudKeep { CloudKeep(details(for: url)) }
    public func hasLocalCopy(_ url: URL) -> Bool {
        let d = details(for: url)
        return d.downloaded || d.kept || d.inheritedFrom != nil || d.bytes > 0
    }
}

/// The offline service the app uses (the engine at launch, the demo one in test instances).
public enum CloudOfflineHub {
    /// Posted with the changed URLs in `userInfo["urls"]` (`[URL]`), or none when anything may have changed.
    public static let changed = CloudOffline.changed
    public static var service: CloudOfflineService?

    /// The URLs a `changed` notification names (nil: anything).
    public static func urls(_ n: Notification) -> [URL]? { n.userInfo?["urls"] as? [URL] }
}
