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
    /// The interrupted job this one resumes: its journal is removed once this one is written, and ignored if a crash
    /// came in between.
    public var replaces: UUID?
    /// Absent in older journals; false for automation transfers.
    public var allowsAuthorization: Bool?

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
    /// Every read and write, in the order they were asked for: a journal begun from the main thread is written here, not
    /// there, and a job's checkpoints, its removal and a later read still follow it.
    private let queue = DispatchQueue(label: "app.porpoise.jobs.journal", qos: .userInitiated)
    private var handles: [UUID: FileHandle] = [:]
    /// The journal the next one begun takes the place of (`handOff`), and hand-offs whose new journal couldn't be written.
    private var replacing: UUID?
    private var failedHandOffs: Set<UUID> = []
    /// Tests: called before each journal file is written, to make it fail.
    var writeFault: ((URL) throws -> Void)?

    public init(folder: URL) { self.folder = folder }

    static var defaultFolder: URL {
        Settings.supportFolder.appendingPathComponent("Jobs")
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }
    private func eventsURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".events.jsonl") }

    private struct Update: Codable {
        let event: JobEvent
        let stagingFingerprint: JobJournal.Fingerprint?
    }

    deinit { for handle in handles.values { try? handle.close() } }

    /// Append small checkpoints instead of re-encoding the entire source list for every completed file.
    /// The baseline remains compatible with existing version-1 journals; replay occurs under the same lock.
    public func record(_ event: JobEvent, id: UUID) {
        queue.sync {
            guard FileManager.default.fileExists(atPath: url(id).path) else { return }
            let fingerprint: JobJournal.Fingerprint?
            if case .copied(_, let point) = event { fingerprint = JobJournal.Fingerprint(point.staging) } else { fingerprint = nil }
            guard let data = try? JSONEncoder().encode(Update(event: event, stagingFingerprint: fingerprint)) else { return }
            let path = eventsURL(id)
            if handles[id] == nil {
                if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
                handles[id] = try? FileHandle(forWritingTo: path)
                _ = try? handles[id]?.seekToEnd()
            }
            try? handles[id]?.write(contentsOf: data + Data([10]))
        }
    }

    private func replay(_ journal: JobJournal) -> JobJournal {
        var journal = journal
        guard let data = try? Data(contentsOf: eventsURL(journal.id)) else { return journal }
        for line in data.split(separator: 10) {
            // A torn trailing write is not a checkpoint. Earlier complete records still apply.
            guard let update = try? JSONDecoder().decode(Update.self, from: Data(line)) else { break }
            journal.apply(update.event)
            if case .copied(let index, _) = update.event, journal.items.indices.contains(index) {
                journal.items[index].stagingFingerprint = update.stagingFingerprint
            }
        }
        return journal
    }

    public func save(_ journal: JobJournal) {
        queue.sync { try? write(journal) }
    }

    /// Writes `journal` and waits until it is on disk, or says why it couldn't be.
    public func persist(_ journal: JobJournal) throws {
        try queue.sync { try write(journal) }
    }

    /// Begins a job's journal without waiting: `make` (which looks at every source) runs and the journal is written on the
    /// journal's queue, before the job's first checkpoint, its removal or any read.
    public func begin(_ make: @escaping @Sendable () -> JobJournal) {
        queue.async { [self] in
            var journal = make()
            guard let old = replacing else {
                try? write(journal)
                return
            }
            replacing = nil
            journal.replaces = old
            // Partial copies carried over are the ones the old journal vouched for.
            for i in journal.items.indices where journal.items[i].staging != nil && journal.items[i].stagingFingerprint == nil {
                journal.items[i].stagingFingerprint = journal.items[i].staging.flatMap(JobJournal.Fingerprint.init)
            }
            do {
                try write(journal)
                removeFiles(old)
            } catch {
                failedHandOffs.insert(old)
            }
        }
    }

    /// Runs `start` (on the main thread), whose job's journal takes the place of `old`: the new one is on disk, naming
    /// `old`, before `old` is removed, so a crash at any moment leaves exactly one record of the work. `then` is told on
    /// the main thread whether that happened; if the new journal couldn't be written, `old` stays.
    public func handOff(from old: UUID, start: () -> Void, then: @escaping (Bool) -> Void) {
        queue.sync { replacing = old }
        start()
        queue.async { [self] in
            let handedOn: Bool
            if replacing == old {
                // The job keeps no journal: nothing to hand on to.
                replacing = nil
                removeFiles(old)
                handedOn = true
            } else {
                handedOn = failedHandOffs.remove(old) == nil
            }
            DispatchQueue.main.async { then(handedOn) }
        }
    }

    /// Waits until every journal asked for is written (before quitting).
    public func flush() {
        queue.sync {}
    }

    /// Replaces the journal file whole and flushes it to disk (then its checkpoints are in it).
    private func write(_ journal: JobJournal) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(journal)
        let target = url(journal.id)
        try writeFault?(target)
        let temporary = folder.appendingPathComponent(".\(journal.id.uuidString).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let dir = open(folder.path, O_RDONLY | O_CLOEXEC)
        if dir >= 0 {
            fsync(dir)
            close(dir)
        }
        try? handles.removeValue(forKey: journal.id)?.close()
        try? FileManager.default.removeItem(at: eventsURL(journal.id))
    }

    public func remove(_ id: UUID) {
        queue.async { [self] in removeFiles(id) }
    }

    private func removeFiles(_ id: UUID) {
        try? handles.removeValue(forKey: id)?.close()
        try? FileManager.default.removeItem(at: url(id))
        try? FileManager.default.removeItem(at: eventsURL(id))
    }

    /// Every journal that can be read (newer versions and damaged files are left alone). One whose job was resumed
    /// under another journal, left behind by a crash during the hand-off, is removed instead.
    public func all() -> [JobJournal] {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let journals = files.filter { $0.pathExtension == "json" }.compactMap { u -> JobJournal? in
                guard let d = try? Data(contentsOf: u), let j = try? JSONDecoder().decode(JobJournal.self, from: d),
                    j.version == JobJournal.currentVersion
                else { return nil }
                return replay(j)
            }
            let replaced = Set(journals.compactMap(\.replaces))
            for id in replaced where journals.contains(where: { $0.id == id }) { removeFiles(id) }
            return journals.filter { !replaced.contains($0.id) }.sorted { $0.created < $1.created }
        }
    }
}
