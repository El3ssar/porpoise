import Foundation
import PorpoiseCore

extension DriveFile: CloudMetadataItem {}

/// Drive's listing identity/membership policy over the shared, wire-compatible metadata cache.
public final class DriveMetadataCache: @unchecked Sendable {
    public typealias Snapshot = CloudMetadataCache<DriveFile>.Snapshot
    public let directory: URL
    let storage: CloudMetadataCache<DriveFile>
    private let keyLock = NSLock()
    // Capability strings must outlive disposable metadata: queued operations may carry only opaque IDs.
    // Account/cache lifetime only, cleared explicitly; this never retains DriveFile or listing payloads.
    private var resourceKeys: [String: String] = [:]
    public init(accountID: UUID, directory: URL? = nil) {
        self.directory = directory ?? Self.root.appendingPathComponent(accountID.uuidString)
        storage = CloudMetadataCache(directory: self.directory)
        storage.trackFreshMetadata()
        retainResourceKeys(storage.files)
    }
    static var root: URL { Settings.supportFolder.appendingPathComponent("Drive") }
    func key(_ location: DriveLocation) -> String {
        switch location.collection {
        case .myDrive: return "root"
        case .sharedWithMe: return "shared"
        case .sharedDrives: return "drives"
        case .folder(let id, _): return "folder:" + id
        }
    }
    public func snapshot(_ location: DriveLocation) -> Snapshot? { storage.snapshot(key(location)) }
    public func file(_ id: String) -> DriveFile? {
        let file = storage.file(id)
        if let file { retainResourceKeys([file]) }
        return file
    }
    private func retainResourceKeys(_ files: [DriveFile]) {
        keyLock.withLock {
            for file in files {
                guard let key = file.resourceKey, DriveLink.isValidID(file.id), DriveLink.isValidID(key) else { continue }
                resourceKeys[file.id] = key
            }
        }
    }
    func resourceKey(_ id: String) -> String? {
        keyLock.withLock { resourceKeys[id] } ?? file(id)?.resourceKey
    }
    /// Where the cache is now: what a request starts from, so that what it reads back doesn't undo a change made here
    /// meanwhile (`learn`, `store`, `apply`).
    var generation: UInt64 { storage.generation }
    func beginRead() -> CloudMetadataLease { storage.beginRead() }
    var files: [DriveFile] { storage.files }
    func remember(_ files: [DriveFile]) { storage.remember(files); retainResourceKeys(files) }
    func learn(_ files: [DriveFile], since: UInt64) -> [DriveFile] {
        let files = storage.learn(files, since: since)
        retainResourceKeys(files); return files
    }
    func rememberRoot(_ file: DriveFile) { storage.alias("root", to: file); retainResourceKeys([file]) }
    func store(_ files: [DriveFile], at location: DriveLocation, since: UInt64? = nil) {
        storage.store(files, key: key(location), since: since)
        retainResourceKeys(storage.snapshot(key(location))?.files ?? [])
    }
    func cursor(_ scope: String) -> String? { storage.cursor(scope) }
    func setCursor(_ token: String?, scope: String) { storage.setCursor(token, scope: scope) }
    var sharedDriveIDs: [String] { Array(Set(storage.files.compactMap(\.driveId))).sorted() }
    func invalidate(_ location: DriveLocation? = nil) { storage.invalidate(location.map(key)) }
    @discardableResult func apply(_ files: [DriveFile], removed: [String], since: UInt64? = nil) -> [String] {
        let root = storage.file("root")?.id ?? "root"
        let removed = storage.apply(
            files, removed: removed,
            belongs: { key, file in
                let parent = key == "root" ? root : String(key.dropFirst("folder:".count))
                return (file.parents ?? []).contains(parent) || (key == "root" && (file.parents ?? []).contains("root"))
            }, retainExisting: { $0 == "shared" || $0 == "drives" }, since: since)
        retainResourceKeys(files.compactMap { storage.file($0.id) })
        return removed
    }
    func invalidateScope(_ scope: String) {
        let folders = storage.files.lazy.filter { scope == "user" ? $0.driveId == nil : $0.driveId == scope }.map { "folder:" + $0.id }
        storage.invalidate(keys: (scope == "user" ? ["root", "shared"] : []) + ["folder:" + scope] + folders)
    }
    public func clear() { storage.clear(); keyLock.withLock { resourceKeys.removeAll() } }
}
