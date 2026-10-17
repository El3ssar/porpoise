import Foundation
import PorpoiseCore

/// One origin ledger and Trash route for jobs, Undo, authorization retries and replacement disposal.
public final class TrashService: @unchecked Sendable {
    public static let shared = TrashService()
    private static let lock = NSLock()
    private let moveToTrash: (URL) throws -> URL?
    public init(moveToTrash: @escaping (URL) throws -> URL? = FileActions.trashItem) { self.moveToTrash = moveToTrash }

    public func trash(_ urls: [URL]) throws -> [(original: URL, inTrash: URL)] {
        do {
            return try FileActions.trashAll(
                urls,
                using: { url in
                    let target = try moveToTrash(url)
                    if let target { record([(original: url, inTrash: target)]) }
                    return target
                })
        } catch {
            // Prune successful rollbacks; retain origins if rollback could not restore an item.
            record([])
            throw error
        }
    }

    public func record(_ pairs: [(original: URL, inTrash: URL)]) {
        Self.lock.withLock {
            var origins = Settings.store.dictionary(forKey: "trashOrigins") as? [String: String] ?? [:]
            for pair in pairs { origins[pair.inTrash.path] = pair.original.path }
            origins = origins.filter { FileJob.itemExists(at: URL(fileURLWithPath: $0.key)) }
            Settings.store.set(origins, forKey: "trashOrigins")
        }
    }

    public func originalLocation(of url: URL) -> URL? {
        Self.lock.withLock {
            (Settings.store.dictionary(forKey: "trashOrigins") as? [String: String])?[url.path].map { URL(fileURLWithPath: $0) }
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
