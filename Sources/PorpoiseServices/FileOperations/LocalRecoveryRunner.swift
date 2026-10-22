import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// The checks and clean-up that come before an interrupted local job runs again, done off the main thread: finishing
/// moves whose copy is complete (an original goes only once its copy is verified and it didn't change meanwhile),
/// proving that each partial copy's good bytes are still the source's, and removing only the partial copies that are
/// still exactly the ones the plan saw. Anything uncertain is kept, and where it is reported.
struct LocalRecoveryRunner {
    let plan: RecoveryPlan
    let control: JobControl
    /// Called on the worker as it goes: what it looks at now, how many steps are done.
    var progress: (String, Int) -> Void = { _, _ in }

    struct Outcome {
        /// The journal as it is now (moves finished, partials removed); written before the rest is handed on.
        var journal: JobJournal?
        var resumePoints: [URL: ResumePoint] = [:]
        /// Destructive plans: the sources that are still the items the plan saw.
        var sources: [URL] = []
        var removedOriginals: [URL] = []
        var errors: [String] = []
        /// Cancelled or interrupted before the end: nothing is handed on, the journal stays.
        var stopped = false
    }

    var steps: Int { plan.unfinishedMoves.count + plan.resumePoints.count + plan.partials.count }

    private var stopped: Bool { control.isCancelled || control.isInterrupted }

    func run() -> Outcome {
        var out = Outcome(journal: plan.journal)
        var done = 0
        for (source, target) in plan.unfinishedMoves {
            if stopped { out.stopped = true; return out }
            progress(source.lastPathComponent, done)
            finishMove(source, target, into: &out)
            done += 1
        }
        for (source, point) in plan.resumePoints.sorted(by: { $0.key.path < $1.key.path }) {
            if stopped { out.stopped = true; return out }
            progress(source.lastPathComponent, done)
            switch Self.prefixMatches(point, of: source, expected: plan.identities[point.staging], cancelled: { stopped }) {
            case nil:
                out.stopped = true
                return out
            case true?:
                out.resumePoints[source] = point
            case false?:
                // Its bytes aren't the source's any more: copied again from the start; the changed file stays.
                out.errors.append(
                    "The partial copy of “\(source.lastPathComponent)” was changed meanwhile: it's copied again from the start, and the changed file is kept at “\(point.staging.path)”."
                )
                forget(staging: point.staging, in: &out.journal)
            }
            done += 1
        }
        for p in plan.partials {
            if stopped { out.stopped = true; return out }
            progress(p.lastPathComponent, done)
            if let kept = Self.removeIfUnchanged(p, expected: plan.identities[p]) {
                out.errors.append(kept)
            } else {
                forget(staging: p, in: &out.journal)
            }
            done += 1
        }
        // Right before a deletion resumes, its items must still be the ones the plan saw.
        for source in plan.sources {
            guard plan.isDestructive else { out.sources.append(source); continue }
            if let expected = plan.identities[source], JobJournal.Fingerprint(source)?.inode == expected.inode {
                out.sources.append(source)
            } else {
                out.errors.append("“\(source.lastPathComponent)” was replaced or removed since: it isn't deleted.")
            }
        }
        if stopped { out.stopped = true }
        return out
    }

    /// Removes `source` once `target` is verified to be its complete copy and `source` hasn't changed while it was
    /// compared.
    private func finishMove(_ source: URL, _ target: URL, into out: inout Outcome) {
        let before = JobJournal.Fingerprint(source)
        let check = CopyVerification.verify(source, target, cancelled: { stopped })
        if check.incomplete { return out.stopped = true }
        guard check.ok else {
            return out.errors.append("“\(source.lastPathComponent)” wasn't removed: its moved copy differs (\(check.summary))")
        }
        guard let before, JobJournal.Fingerprint(source) == before else {
            return out.errors.append("“\(source.lastPathComponent)” wasn't removed: it changed while its moved copy was checked.")
        }
        do {
            try FileManager.default.removeItem(at: source)
        } catch {
            return out.errors.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        out.removedOriginals.append(source)
        if let i = out.journal?.items.firstIndex(where: { $0.source == source && $0.state == .placed }) {
            out.journal?.items[i].state = .done
        }
    }

    private func forget(staging: URL, in journal: inout JobJournal?) {
        guard let i = journal?.items.firstIndex(where: { $0.staging == staging }) else { return }
        journal?.items[i].staging = nil
        journal?.items[i].offset = nil
        journal?.items[i].stagingFingerprint = nil
    }

    /// Removes a partial copy only if it is still exactly the item the plan saw; otherwise keeps it and says where.
    static func removeIfUnchanged(_ url: URL, expected: JobJournal.Fingerprint?) -> String? {
        guard let now = JobJournal.Fingerprint(url) else { return nil }  // already gone
        guard let expected, now == expected else {
            return "A partial copy was replaced or changed since it was checked, so it's kept: “\(url.path)”."
        }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            return "A partial copy couldn't be removed: “\(url.path)” (\(error.localizedDescription))."
        }
    }

    /// Whether the first `point.offset` bytes of the partial copy are still the source's, byte for byte, and the partial
    /// is still the item the plan saw; nil when cancelled.
    static func prefixMatches(_ point: ResumePoint, of source: URL, expected: JobJournal.Fingerprint?, cancelled: () -> Bool) -> Bool? {
        guard let expected, JobJournal.Fingerprint(point.staging) == expected, expected.size >= point.offset else { return false }
        guard let a = FileHandle(forReadingAtPath: source.path), let b = FileHandle(forReadingAtPath: point.staging.path) else { return false }
        defer {
            try? a.close()
            try? b.close()
        }
        var left = point.offset
        while left > 0 {
            if cancelled() { return nil }
            let same: Bool? = autoreleasepool {
                let n = Int(min(left, 1 << 20))
                guard let x = try? a.read(upToCount: n), let y = try? b.read(upToCount: n), x.count == n, y.count == n else { return nil }
                return x == y
            }
            guard same == true else { return false }
            left -= Int64(min(left, 1 << 20))
        }
        return true
    }
}
