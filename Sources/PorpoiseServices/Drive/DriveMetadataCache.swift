import Foundation
import PorpoiseCore

/// Versioned, account-private metadata only. A damaged snapshot is discarded and rebuilt online.
public final class DriveMetadataCache: @unchecked Sendable {
    public struct Snapshot: Codable, Sendable {
        public var files: [DriveFile]
        public var savedAt: Date
    }
    private struct State: Codable {
        var schema = 1
        var files: [String: DriveFile] = [:]
        var listings: [String: Snapshot] = [:]
        var cursors: [String: String] = [:]
    }
    private let lock = NSLock()
    private var state: State
    public let directory: URL
    private var path: URL { directory.appendingPathComponent("metadata.json") }

    public init(accountID: UUID, directory: URL? = nil) {
        self.directory = directory ?? Self.root.appendingPathComponent(accountID.uuidString)
        let path = self.directory.appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: path), let decoded = try? JSONDecoder().decode(State.self, from: data), decoded.schema == 1 {
            state = decoded
        } else {
            state = State()
        }
    }
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Porpoise/Drive")
    }
    private func key(_ location: DriveLocation) -> String {
        switch location.collection {
        case .myDrive: return "root"
        case .sharedWithMe: return "shared"
        case .sharedDrives: return "drives"
        case .folder(let id, _): return "folder:" + id
        }
    }
    public func snapshot(_ location: DriveLocation) -> Snapshot? { lock.withLock { state.listings[key(location)] } }
    public func file(_ id: String) -> DriveFile? { lock.withLock { state.files[id] } }
    func remember(_ files: [DriveFile]) {
        lock.withLock {
            for file in files { state.files[file.id] = file }
            persist()
        }
    }
    func store(_ files: [DriveFile], at location: DriveLocation) {
        lock.withLock {
            state.listings[key(location)] = Snapshot(files: files, savedAt: Date())
            for file in files { state.files[file.id] = file }
            persist()
        }
    }
    func cursor(_ scope: String) -> String? { lock.withLock { state.cursors[scope] } }
    func setCursor(_ token: String?, scope: String) {
        lock.withLock {
            state.cursors[scope] = token; persist()
        }
    }
    var sharedDriveIDs: [String] { lock.withLock { Array(Set(state.files.values.compactMap(\.driveId))).sorted() } }
    func invalidate(_ location: DriveLocation? = nil) {
        lock.withLock {
            if let location { state.listings[key(location)] = nil } else { state.listings.removeAll() }
            persist()
        }
    }
    /// Invalidate every collection on a feed event: moves/deletions can affect old parents and virtual collections.
    func apply(_ files: [DriveFile], removed: [String]) {
        lock.withLock {
            for id in removed { state.files[id] = nil }
            for file in files { state.files[file.id] = file }
            for key in state.listings.keys {
                guard var snapshot = state.listings[key] else { continue }
                snapshot.files.removeAll { removed.contains($0.id) }
                for file in files where !removed.contains(file.id) {
                    let parent = key == "root" ? (state.files["root"]?.id ?? "root") : String(key.dropFirst("folder:".count))
                    let inFolder = (file.parents ?? []).contains(parent) || (key == "root" && (file.parents ?? []).contains("root"))
                    if let index = snapshot.files.firstIndex(where: { $0.id == file.id }) {
                        if key == "shared" || key == "drives" || inFolder { snapshot.files[index] = file } else { snapshot.files.remove(at: index) }
                    } else if inFolder {
                        snapshot.files.append(file)
                    }
                }
                state.listings[key] = snapshot
            }
            persist()
        }
    }
    public func clear() {
        lock.withLock {
            state = State(); try? FileManager.default.removeItem(at: path)
        }
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { /* Metadata is disposable; failed writes never discard an in-memory listing. */  }
    }
}
