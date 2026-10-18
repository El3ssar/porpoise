import Foundation
import PorpoiseCore
import PorpoiseFileSystem

// MARK: Trash origins ("Restore to Former Location")

extension FileOperationsController {
    var replacementDisposal: ((URL, URL) throws -> Void)? {
        Settings.isTesting ? nil : { try TrashService.shared.disposeReplacement($0, original: $1) }
    }

    /// Moves items back from the Trash to where they came from; returns the ones with unknown origins.
    public func restore(_ urls: [URL], window: AnyObject?) -> [URL] {
        let fm = FileManager.default
        var unknown: [URL] = []
        var pairs: [(URL, URL)] = []
        for u in urls {
            guard let orig = TrashService.shared.originalLocation(of: u) else { unknown.append(u); continue }
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
