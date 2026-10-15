import Foundation
import PorpoiseCore

/// What an unfinished job had done, saved as it goes so it can be resumed after a quit or a crash: for each
/// top-level item whether it is done, and for a large file being copied, its partial copy and how far it got.
/// One versioned JSON file per job; removed when the job ends.
public struct JobJournal: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Fingerprint: Codable, Equatable, Sendable {
        public var size: Int64
        public var modified: Double
        public var inode: UInt64

        /// The item's size, date and inode (lstat), nil when it's gone.
        public init?(_ url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            size = Int64(st.st_size)
            modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            inode = UInt64(st.st_ino)
        }
    }

    public enum ItemState: String, Codable, Sendable {
        case pending, started, placed, done, skipped, failed, cancelled
    }

    public struct Item: Codable, Equatable, Sendable {
        public var source: URL
        public var fingerprint: Fingerprint?
        public var state: ItemState = .pending
        /// The hidden partial copy, and for a resumable one how many bytes of it are good.
        public var staging: URL?
        public var offset: Int64?
        public var stagingFingerprint: Fingerprint?
        public var target: URL?
    }

    public var version = Self.currentVersion
    public var id: UUID
    public var kind: String
    public var destination: URL?
    public var created: Date
    public var items: [Item]

    public init(id: UUID, kind: FileOperationKind, sources: [URL], destination: URL?) {
        self.id = id
        self.kind = kind.rawValue
        self.destination = destination
        created = Date()
        items = sources.map { Item(source: $0, fingerprint: Fingerprint($0)) }
    }

    public var operation: FileOperationKind? { FileOperationKind(rawValue: kind) }

    /// Takes in what the job reported.
    public mutating func apply(_ event: JobEvent) {
        switch event {
        case .started(let i, let staging):
            guard items.indices.contains(i) else { return }
            items[i].state = .started
            items[i].staging = staging
            items[i].offset = nil
        case .copied(let i, let point):
            guard items.indices.contains(i) else { return }
            items[i].staging = point.staging
            items[i].offset = point.offset
            items[i].stagingFingerprint = Fingerprint(point.staging)
        case .placed(let i, let target):
            guard items.indices.contains(i) else { return }
            items[i].state = .placed
            items[i].target = target
            items[i].staging = nil
            items[i].offset = nil
        case .finished(let i, let outcome):
            guard items.indices.contains(i) else { return }
            switch outcome {
            case .done: items[i].state = .done
            case .skipped: items[i].state = .skipped
            case .failed: items[i].state = .failed
            case .cancelled: items[i].state = .cancelled
            }
        }
    }
}

/// The journals on disk (Application Support/Porpoise/Jobs). Thread-safe: jobs write from their own threads.
public final class JournalStore: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()

    public init(folder: URL) { self.folder = folder }

    static var defaultFolder: URL {
        if Settings.isTesting { return FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-test-jobs-\(getpid())") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise/Jobs")
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    public func save(_ journal: JobJournal) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try? enc.encode(journal).write(to: url(journal.id), options: .atomic)
        }
    }

    public func remove(_ id: UUID) { lock.withLock { try? FileManager.default.removeItem(at: url(id)) } }

    /// Every journal that can be read (newer versions and damaged files are left alone).
    public func all() -> [JobJournal] {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { u in
                guard let d = try? Data(contentsOf: u), let j = try? JSONDecoder().decode(JobJournal.self, from: d),
                    j.version == JobJournal.currentVersion
                else { return nil }
                return j
            }.sorted { $0.created < $1.created }
        }
    }
}
