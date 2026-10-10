import Foundation
import PorpoiseCore

// MARK: Trash origins ("Restore to Former Location")

extension FileOperationsController {
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
