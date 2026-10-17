import Foundation
import PorpoiseCore

extension DriveFile: CloudMetadataItem {}

/// Drive's listing identity/membership policy over the shared, wire-compatible metadata cache.
public final class DriveMetadataCache: @unchecked Sendable {
    public typealias Snapshot = CloudMetadataCache<DriveFile>.Snapshot
    public let directory: URL
    private let storage: CloudMetadataCache<DriveFile>
    public init(accountID: UUID, directory: URL? = nil) {
        self.directory = directory ?? Self.root.appendingPathComponent(accountID.uuidString)
        storage = CloudMetadataCache(directory: self.directory)
    }
    static var root: URL { Settings.supportFolder.appendingPathComponent("Drive") }
    private func key(_ location: DriveLocation) -> String {
        switch location.collection {
        case .myDrive: return "root"
        case .sharedWithMe: return "shared"
        case .sharedDrives: return "drives"
        case .folder(let id, _): return "folder:" + id
        }
    }
    public func snapshot(_ location: DriveLocation) -> Snapshot? { storage.snapshot(key(location)) }
    public func file(_ id: String) -> DriveFile? { storage.file(id) }
    /// Where the cache is now: what a request starts from, so that what it reads back doesn't undo a change made here
    /// meanwhile (`learn`, `store`, `apply`).
    var generation: UInt64 { storage.generation }
    func remember(_ files: [DriveFile]) { storage.remember(files) }
    func learn(_ files: [DriveFile], since: UInt64) -> [DriveFile] { storage.learn(files, since: since) }
    func rememberRoot(_ file: DriveFile) { storage.alias("root", to: file) }
    func store(_ files: [DriveFile], at location: DriveLocation, since: UInt64? = nil) {
        storage.store(files, key: key(location), since: since)
    }
    func cursor(_ scope: String) -> String? { storage.cursor(scope) }
    func setCursor(_ token: String?, scope: String) { storage.setCursor(token, scope: scope) }
    var sharedDriveIDs: [String] { Array(Set(storage.files.compactMap(\.driveId))).sorted() }
    func invalidate(_ location: DriveLocation? = nil) { storage.invalidate(location.map(key)) }
    func apply(_ files: [DriveFile], removed: [String], since: UInt64? = nil) {
        let root = storage.file("root")?.id ?? "root"
        storage.apply(
            files, removed: removed,
            belongs: { key, file in
                let parent = key == "root" ? root : String(key.dropFirst("folder:".count))
                return (file.parents ?? []).contains(parent) || (key == "root" && (file.parents ?? []).contains("root"))
            }, retainExisting: { $0 == "shared" || $0 == "drives" }, since: since)
    }
    public func clear() { storage.clear() }
}
