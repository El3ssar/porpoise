import Foundation
import PorpoiseCore

// MARK: Trash origins ("Restore to Former Location")

extension FileOperationsController {
    /// Called by a worker after atomic publication. Trash receives a readable original basename, while
    /// failures restore the displaced staging path so FileJob can swap the old target back.
    func configureReplacementDisposal(_ job: FileJob) {
        guard !Settings.isTesting else { return }
        job.disposeReplacedItem = { [weak self] staged, original in
            let fm = FileManager.default
            let holding = staged.deletingLastPathComponent().appendingPathComponent(".porpoise-replaced-" + UUID().uuidString)
            try fm.createDirectory(at: holding, withIntermediateDirectories: false)
            let named = holding.appendingPathComponent(original.lastPathComponent)
            do { try fm.moveItem(at: staged, to: named) } catch { _ = rmdir(holding.path); throw error }
            var trashed: NSURL?
            do { try fm.trashItem(at: named, resultingItemURL: &trashed) } catch {
                do { try fm.moveItem(at: named, to: staged) } catch let restoreError {
                    throw FileOperationError.failed(
                        "The previous item is kept at “\(named.path)”. It could not be returned to staging: \(restoreError.localizedDescription)")
                }
                _ = rmdir(holding.path)
                throw error
            }
            _ = rmdir(holding.path)
            if let trashed = trashed as URL? {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    var origins = self.trashOrigins
                    origins[trashed.path] = original.path
                    self.trashOrigins = origins
                }
            }
        }
    }

    /// Original locations of items this app moved to the Trash (macOS has no public "Put Back" API).
    private var trashOrigins: [String: String] {
        get { Settings.store.dictionary(forKey: "trashOrigins") as? [String: String] ?? [:] }
        set { Settings.store.set(newValue, forKey: "trashOrigins") }
    }

    func recordTrash(_ record: UndoRecord) {
        guard case .trashed(let pairs) = record else { return }
        var d = trashOrigins
        for p in pairs { d[p.inTrash.path] = p.original.path }
        // Forget entries whose trash file is gone.
        d = d.filter { FileJob.itemExists(at: URL(fileURLWithPath: $0.key)) }
        trashOrigins = d
    }

    func originalLocation(of trashed: URL) -> URL? { trashOrigins[trashed.path].map { URL(fileURLWithPath: $0) } }

    /// Moves items back from the Trash to where they came from; returns the ones with unknown origins.
    public func restore(_ urls: [URL], window: AnyObject?) -> [URL] {
        let fm = FileManager.default
        var unknown: [URL] = []
        var pairs: [(URL, URL)] = []
        for u in urls {
            guard let orig = originalLocation(of: u) else { unknown.append(u); continue }
            let parent = orig.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                var dest = orig
                if FileJob.itemExists(at: dest) {
                    let existing = Set((try? fm.contentsOfDirectory(atPath: parent.path)) ?? [])
                    dest = parent.appendingPathComponent(FileFormat.suggestedName(for: orig.lastPathComponent, existing: existing))
                }
                try fm.moveItem(at: u, to: dest)
                pairs.append((u, dest))
            } catch { showErrors([error.localizedDescription], window: window) }
        }
        if !pairs.isEmpty {
            pushUndo(.moved(pairs.map { (from: $0.0, to: $0.1) }))
            Self.notifyChanged(pairs.flatMap { [$0.0, $0.1] })
        }
        return unknown
    }
}
