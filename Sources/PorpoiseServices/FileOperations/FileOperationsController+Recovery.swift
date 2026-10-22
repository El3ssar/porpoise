import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// A job that didn't finish last time (Porpoise quit, crashed or the Mac lost power), checked against the disk as it
/// is now: what can be resumed, what changed meanwhile.
public struct RecoveryPlan: Identifiable, Sendable {
    public let id: UUID
    public let kind: FileOperationKind
    public let destination: URL?
    /// Items to process again; large files with a good partial copy continue from it.
    public var sources: [URL] = []
    var cloudBatchID: UUID?
    var cloudOperations: [URL: UUID] = [:]
    public var resumePoints: [URL: ResumePoint] = [:]
    /// Moves whose copy was complete when the job stopped, but whose original wasn't removed yet.
    public var unfinishedMoves: [(source: URL, target: URL)] = []
    /// Partial copies this job made that can't be continued: removed when resuming or discarding.
    var partials: [URL] = []
    /// What the partial copies (and, for a deletion, the items left) were when the plan was made: one is removed or
    /// deleted only while it is still that item.
    var identities: [URL: JobJournal.Fingerprint] = [:]
    /// The journal it was made from (local jobs).
    var journal: JobJournal?
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
        let local = journals.all().filter { !live.contains($0.id) }.compactMap(Self.plan)
        let records = recoveryTransferJournals().flatMap { (try? $0.all()) ?? [] }
        let cloud = Dictionary(records.map { ($0.operationID, $0) }, uniquingKeysWith: { a, _ in a }).values.compactMap { record -> RecoveryPlan? in
            guard record.topLevel, record.phase != .done, !live.contains(record.batchID ?? record.operationID),
                !CloudTransferJournal.isActive(record)
            else { return nil }
            var plan = RecoveryPlan(id: record.operationID, kind: record.kind == "move" ? .move : .copy, destination: record.destinationFolder)
            plan.cloudBatchID = record.batchID; plan.sources = [record.source]; plan.cloudOperations = [record.source: record.operationID]
            if record.phase == .sourceRemovalPending {
                plan.notes = ["Source removal was interrupted. Review the source before retrying; it will not be removed automatically."]
            }
            return plan
        }
        return local + cloud
    }

    private func recoveryTransferJournals() -> [CloudTransferJournal] {
        if let cloudTransferJournals { return cloudTransferJournals }
        let all = [DriveProvider.transferJournal(driveJournals), .shared] + RemoteFS.transferJournals + CloudTransferJournal.known
        return Array(Dictionary(all.map { ($0.folder, $0) }, uniquingKeysWith: { a, _ in a }).values)
    }

    /// What can be resumed of `journal`. Items in progress are continued only if their source is unchanged (size,
    /// date and inode) and their partial copy is the one the job wrote; otherwise they start over. Whether its good bytes
    /// are still the source's is checked when it's resumed.
    static func plan(_ journal: JobJournal) -> RecoveryPlan? {
        guard let kind = journal.operation else { return nil }
        var plan = RecoveryPlan(id: journal.id, kind: kind, destination: journal.destination)
        plan.journal = journal
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
            case .pending, .started:
                guard let now else {
                    plan.notes.append("“\(name)” is no longer there.")
                    if let s = item.staging, let current = JobJournal.Fingerprint(s), owns(item, staging: s, current, journal) {
                        plan.partials.append(s)
                        plan.identities[s] = current
                    }
                    continue
                }
                if plan.isDestructive {
                    // Deleting goes by name: never delete another item that took this one's place.
                    guard let saved = item.fingerprint, saved.inode == now.inode else {
                        plan.notes.append("“\(name)” was replaced by another item since: it isn't deleted.")
                        continue
                    }
                    plan.identities[item.source] = now
                }
                plan.sources.append(item.source)
                // A resumed job's items carry their partial copies from the start, before they are started again.
                guard let staging = item.staging, let current = JobJournal.Fingerprint(staging) else { continue }
                guard owns(item, staging: staging, current, journal) else {
                    plan.notes.append(
                        "The partial copy of “\(name)” was changed meanwhile: it's copied again from the start (the changed file is kept).")
                    continue
                }
                plan.identities[staging] = current
                let unchanged = item.fingerprint == now
                if !unchanged {
                    plan.notes.append("“\(name)” changed since: it's copied again from the start.")
                    plan.partials.append(staging)
                } else if let offset = item.offset, offset > 0, current.size >= offset {
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

    /// Whether the item at a partial copy's place is the one the job wrote: the inode its last checkpoint saw, or, before
    /// any checkpoint, an item at the job's hidden name made after the job began.
    private static func owns(_ item: JobJournal.Item, staging: URL, _ current: JobJournal.Fingerprint, _ journal: JobJournal) -> Bool {
        if let saved = item.stagingFingerprint { return saved.inode == current.inode }
        var st = stat()
        guard lstat(staging.path, &st) == 0 else { return false }
        let born = Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1e9
        // A little slack: the journal's date and the file system's clock are read at different moments.
        return born >= journal.created.timeIntervalSince1970 - 2
    }

    /// Resumes a plan: off the main thread, as an Activity that can be cancelled, finishes interrupted moves (removing
    /// an original only once its copy is verified and it didn't change meanwhile), checks that each partial copy still
    /// holds the source's bytes, removes partial copies that can't be continued, then runs the rest as a new job whose
    /// journal takes the old one's place. Until then, and if that journal can't be written, the old one stays.
    public func recover(_ plan: RecoveryPlan, window: AnyObject?, done: (([URL]) -> Void)? = nil) {
        isInterrupting = false
        if !plan.cloudOperations.isEmpty {
            runRemote(
                plan.kind, plan.sources, to: plan.destination, window: window, done: done, cloudOperations: plan.cloudOperations,
                cloudBatchID: plan.cloudBatchID)
            return
        }
        let control = JobControl()
        let activity = Activity(
            kind: plan.kind, sources: plan.sources + plan.unfinishedMoves.map(\.source), destination: plan.destination, job: nil, control: control)
        let dest = plan.destination.map { " to “\($0.lastPathComponent)”" } ?? ""
        activity.cloudTitle = "Checking before resuming: \(plan.kind.verb)\(dest)"
        activity.originWindow = window
        var runner = LocalRecoveryRunner(plan: plan, control: control)
        let steps = runner.steps
        runner.progress = { [weak self, weak activity] name, step in
            DispatchQueue.main.async {
                guard let activity else { return }
                activity.progress?.currentName = name
                activity.progress?.doneItems = step
                activity.progress?.totalItems = steps
                self?.activityDidChange()
            }
        }
        activity.start = { [weak self, weak activity] in
            guard let self, let activity, activity.state == .queued else { return }
            activity.state = .verifying
            activity.startedAt = Date()
            let store = self.journals
            DispatchQueue.global(qos: .userInitiated).async {
                var out = runner.run()
                // Written whole before anything is handed on: if it can't be, nothing is resumed and the record stays.
                if !out.stopped, let journal = out.journal {
                    do { try store.persist(journal) } catch {
                        out.errors.append(
                            "Porpoise couldn't update its record of the interrupted job, so it isn't resumed now; it's offered again next time. (\(error.localizedDescription))"
                        )
                        out.stopped = true
                    }
                }
                control.finish()
                DispatchQueue.main.async { self.finishRecovery(plan, activity, out, window: window, done: done) }
            }
        }
        enqueue(activity)
    }

    private func finishRecovery(
        _ plan: RecoveryPlan, _ activity: Activity, _ out: LocalRecoveryRunner.Outcome, window: AnyObject?, done: (([URL]) -> Void)?
    ) {
        activity.remoteResults = out.removedOriginals
        Self.notifyChanged(plan.unfinishedMoves.map(\.source) + plan.unfinishedMoves.map(\.target))
        let rest = plan.isDestructive ? out.sources : plan.sources
        // Cancelled, interrupted (the app quitting) or not recorded: the old journal stays, to be offered again.
        let handOn = !out.stopped && !activity.control.isCancelled && !activity.control.isInterrupted && !isInterrupting
        ended(activity, errors: out.errors)
        if !out.errors.isEmpty { showErrors(out.errors, window: window) }
        guard handOn else { return }
        guard !rest.isEmpty else { return journals.remove(plan.id) }
        var next: Activity?
        journals.handOff(from: plan.id) {
            run(plan.kind, rest, to: plan.destination, window: window, resumePoints: out.resumePoints, done: done)
            next = activities.last
        } then: { [weak self] handedOn in
            guard let self, !handedOn else { return }
            // The resumed job has no record of its own: the old one stays until it ends, and is offered again if it's
            // interrupted.
            self.showErrors(
                ["Porpoise couldn't write the record of the resumed job: if it's interrupted, it's offered again from the earlier record."],
                window: window)
            self.retireJournal(plan.id, after: next)
        }
    }

    /// Removes journal `id` once `activity` ends other than by an interruption.
    private func retireJournal(_ id: UUID, after activity: Activity?) {
        guard let activity, !activity.state.isEnded else {
            if activity?.state != .interrupted { journals.remove(id) }
            return
        }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: Self.activityChanged, object: self, queue: .main) { [weak self] _ in
            guard activity.state.isEnded else { return }
            if activity.state != .interrupted { self?.journals.remove(id) }
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    /// Forgets a plan, removing the partial copies it made: only those that are still exactly what the plan saw (the
    /// items it finished stay, and so does anything that took a partial copy's place, whose location is reported).
    public func discard(_ plan: RecoveryPlan) {
        for journal in recoveryTransferJournals() {
            for id in plan.cloudOperations.values {
                if var record = try? journal.load(id) { record.phase = .done; try? journal.save(record) }
            }
        }
        let partials = plan.partials + plan.resumePoints.values.map(\.staging)
        let kept = partials.compactMap { LocalRecoveryRunner.removeIfUnchanged($0, expected: plan.identities[$0]) }
        journals.remove(plan.id)
        if !kept.isEmpty { showErrors(kept, window: nil) }
    }
}
