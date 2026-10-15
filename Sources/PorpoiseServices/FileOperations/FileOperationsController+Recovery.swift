import Foundation
import PorpoiseCore

/// A job that didn't finish last time (Porpoise quit, crashed or the Mac lost power), checked against the disk as it
/// is now: what can be resumed, what changed meanwhile.
public struct RecoveryPlan: Identifiable, Sendable {
    public let id: UUID
    public let kind: FileOperationKind
    public let destination: URL?
    /// Items to process again; large files with a good partial copy continue from it.
    public var sources: [URL] = []
    public var resumePoints: [URL: ResumePoint] = [:]
    /// Moves whose copy was complete when the job stopped, but whose original wasn't removed yet.
    public var unfinishedMoves: [(source: URL, target: URL)] = []
    /// Partial copies this job made that can't be continued: removed when resuming or discarding.
    var partials: [URL] = []
    /// What isn't resumed, or is started over, and why.
    public var notes: [String] = []
    /// Deleting or trashing: never resumed without asking.
    public var isDestructive: Bool { kind == .delete || kind == .trash }
    public var isEmpty: Bool { sources.isEmpty && unfinishedMoves.isEmpty }

    /// "Copying 3 items to Backup was interrupted: 2 items are left (512 MB already copied)."
    public var summary: String {
        let left = sources.count + unfinishedMoves.count
        let dest = destination.map { " to “\($0.lastPathComponent)”" } ?? ""
        let copied = resumePoints.values.reduce(Int64(0)) { $0 + $1.offset }
        let done = copied > 0 ? " (\(FileFormat.size(copied)) already copied)" : ""
        return "\(kind.verb)\(dest) was interrupted: \(left) \(left == 1 ? "item is" : "items are") left\(done)."
    }
}

extension FileOperationsController {
    /// Unfinished jobs from earlier runs (not the ones running now), checked against the disk.
    public func recoveryPlans() -> [RecoveryPlan] {
        let live = Set(activities.filter { !$0.state.isEnded }.map(\.id))
        return journals.all().filter { !live.contains($0.id) }.compactMap(Self.plan)
    }

    /// What can be resumed of `journal`. Items in progress are continued only if their source is unchanged (size,
    /// date and inode) and their partial copy is the one the job wrote; otherwise they start over.
    static func plan(_ journal: JobJournal) -> RecoveryPlan? {
        guard let kind = journal.operation else { return nil }
        var plan = RecoveryPlan(id: journal.id, kind: kind, destination: journal.destination)
        if let d = journal.destination, !FileJob.itemExists(at: d) {
            plan.notes.append("The destination “\(d.lastPathComponent)” is no longer there.")
            // Our partial copies went with it; nothing to resume.
            return plan
        }
        for item in journal.items {
            let name = item.source.lastPathComponent
            let now = JobJournal.Fingerprint(item.source)
            switch item.state {
            case .done, .skipped, .failed, .cancelled:
                continue
            case .pending:
                if now == nil {
                    plan.notes.append("“\(name)” is no longer there.")
                } else {
                    plan.sources.append(item.source)
                }
            case .started:
                guard let now else {
                    plan.notes.append("“\(name)” is no longer there.")
                    if let s = item.staging, item.stagingFingerprint == nil || item.stagingFingerprint?.inode == JobJournal.Fingerprint(s)?.inode {
                        plan.partials.append(s)
                    }
                    continue
                }
                plan.sources.append(item.source)
                guard let staging = item.staging, FileJob.itemExists(at: staging) else { continue }
                let current = JobJournal.Fingerprint(staging)
                let ours = item.stagingFingerprint.map { $0.inode == current?.inode } ?? true
                guard ours else {
                    plan.notes.append(
                        "The partial copy of “\(name)” was changed meanwhile: it's copied again from the start (the changed file is kept).")
                    continue
                }
                let unchanged = item.fingerprint == now
                if !unchanged {
                    plan.notes.append("“\(name)” changed since: it's copied again from the start.")
                    plan.partials.append(staging)
                } else if let offset = item.offset, offset > 0, let c = current, c.size >= offset {
                    plan.resumePoints[item.source] = ResumePoint(staging: staging, offset: offset)
                } else {
                    plan.partials.append(staging)  // can't be continued (a folder, a small file): started over
                }
            case .placed:
                // Complete at its place; a move still had to remove its original.
                guard kind == .move, let target = item.target, now != nil else { continue }
                if FileJob.itemExists(at: target) {
                    plan.unfinishedMoves.append((item.source, target))
                } else {
                    plan.notes.append("The moved copy of “\(name)” is gone; the original is kept.")
                }
            }
        }
        return plan
    }

    /// Resumes a plan: finishes interrupted moves (removing an original only once its copy is checked to be
    /// identical), removes partial copies that can't be continued, then runs the rest as a new job.
    public func recover(_ plan: RecoveryPlan, window: AnyObject?, done: (([URL]) -> Void)? = nil) {
        journals.remove(plan.id)
        var errors: [String] = []
        for (source, target) in plan.unfinishedMoves {
            let check = CopyVerification.verify(source, target)
            if check.ok {
                do { try FileManager.default.removeItem(at: source) } catch {
                    errors.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            } else {
                errors.append("“\(source.lastPathComponent)” wasn't removed: its moved copy differs (\(check.summary))")
            }
        }
        for p in plan.partials { try? FileManager.default.removeItem(at: p) }
        if !errors.isEmpty { showErrors(errors, window: window) }
        Self.notifyChanged(plan.unfinishedMoves.map(\.source) + plan.unfinishedMoves.map(\.target))
        guard !plan.sources.isEmpty else { return }
        run(plan.kind, plan.sources, to: plan.destination, window: window, resumePoints: plan.resumePoints, done: done)
    }

    /// Forgets a plan, removing the partial copies it made (only those: the items it finished stay).
    public func discard(_ plan: RecoveryPlan) {
        for p in plan.partials { try? FileManager.default.removeItem(at: p) }
        for point in plan.resumePoints.values { try? FileManager.default.removeItem(at: point.staging) }
        journals.remove(plan.id)
    }
}
