import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// One origin ledger and Trash route for jobs, Undo, authorization retries and replacement disposal.
public final class TrashService: @unchecked Sendable {
    public static let shared = TrashService()
    private static let lock = NSLock()
    private static let persistence = DispatchQueue(label: "porpoise.trash-origins", qos: .utility)
    private static var cached: Ledger?

    private final class Ledger {
        let store: UserDefaults
        var origins: [String: String]
        var dirty = false
        var writeScheduled = false
        var pruning = false
        init(store: UserDefaults) {
            self.store = store
            origins = store.dictionary(forKey: "trashOrigins") as? [String: String] ?? [:]
        }
    }

    /// Called with `lock` held. Settings isolation can replace the store between test runs.
    private static func ledger() -> Ledger {
        if let cached, cached.store === Settings.store { return cached }
        let value = Ledger(store: Settings.store)
        cached = value
        return value
    }

    private static func persist(_ ledger: Ledger) {
        // One writer holds the lock so an older snapshot cannot overwrite a newer flush.
        guard ledger.dirty else { return }
        ledger.store.set(ledger.origins, forKey: "trashOrigins")
        ledger.dirty = false
    }

    private static func scheduleWrite(_ ledger: Ledger) {
        guard !ledger.writeScheduled else { return }
        ledger.writeScheduled = true
        persistence.asyncAfter(deadline: .now() + 0.25) {
            lock.withLock {
                ledger.writeScheduled = false
                persist(ledger)
            }
        }
    }
    private let moveToTrash: (URL) throws -> URL?
    public init(moveToTrash: @escaping (URL) throws -> URL? = FileActions.trashItem) { self.moveToTrash = moveToTrash }

    public func trash(_ urls: [URL]) throws -> [(original: URL, inTrash: URL)] {
        var pairs: [(original: URL, inTrash: URL)] = []
        do {
            let result = try FileActions.trashAll(
                urls,
                using: { url in
                    let target = try moveToTrash(url)
                    if let target { pairs.append((original: url, inTrash: target)) }
                    return target
                })
            record(result)
            return result
        } catch {
            // Core rolled back completed moves; retain origins if any rollback could not restore its item.
            record(pairs.filter { FileJob.itemExists(at: $0.inTrash) })
            throw error
        }
    }

    /// Origins are immediately available to Restore. Disk writes coalesce across a batch of jobs.
    /// Empty batches request an off-main prune; they never scan Trash on the caller's thread.
    public func record(_ pairs: [(original: URL, inTrash: URL)]) {
        Self.lock.withLock {
            let ledger = Self.ledger()
            if pairs.isEmpty {
                guard !ledger.pruning else { return }
                ledger.pruning = true
                Self.persistence.async {
                    let snapshot = Self.lock.withLock { ledger.origins }
                    let stale = snapshot.filter { entry in
                        autoreleasepool { !FileJob.itemExists(at: URL(fileURLWithPath: entry.key)) }
                    }
                    Self.lock.withLock {
                        for (path, original) in stale where ledger.origins[path] == original {
                            // An item could have returned to this path while the prune was scanning.
                            if !FileJob.itemExists(at: URL(fileURLWithPath: path)) {
                                ledger.origins[path] = nil; ledger.dirty = true
                            }
                        }
                        ledger.pruning = false
                        Self.persist(ledger)
                    }
                }
            } else {
                for pair in pairs { ledger.origins[pair.inTrash.path] = pair.original.path }
                ledger.dirty = true
                Self.scheduleWrite(ledger)
            }
        }
    }

    /// Job completion/quit can make the coalesced ledger durable before returning.
    public func flush() {
        let ledger = Self.lock.withLock { Self.ledger() }
        // Prunes requested before this job boundary finish before its durable snapshot.
        Self.persistence.sync { Self.lock.withLock { Self.persist(ledger) } }
    }

    public func originalLocation(of url: URL) -> URL? {
        Self.lock.withLock {
            Self.ledger().origins[url.path].map { URL(fileURLWithPath: $0) }
        }
    }

    /// Disposal happens only after atomic publication. Restore the displaced stage if Trash refuses it.
    public func disposeReplacement(_ staged: URL, original: URL) throws {
        let fm = FileManager.default
        let holding = staged.deletingLastPathComponent().appendingPathComponent(".porpoise-replaced-" + UUID().uuidString)
        try fm.createDirectory(at: holding, withIntermediateDirectories: false)
        let named = holding.appendingPathComponent(original.lastPathComponent)
        do { try fm.moveItem(at: staged, to: named) } catch { _ = rmdir(holding.path); throw error }
        var trashed: URL?
        do { trashed = try moveToTrash(named) } catch {
            do { try fm.moveItem(at: named, to: staged) } catch let restoreError {
                throw FileOperationError.failed(
                    "The previous item is kept at “\(named.path)”. It could not be returned to staging: \(restoreError.localizedDescription)")
            }
            _ = rmdir(holding.path)
            throw error
        }
        _ = rmdir(holding.path)
        if let trashed { record([(original: original, inTrash: trashed)]) }
    }
}
