import Foundation
import PorpoiseCore

/// One job as the Activity window shows it: waiting in the queue, running, paused, waiting for an answer, or ended.
/// Main thread only.
public final class Activity: Identifiable {
    public enum State: String, Sendable {
        case queued, running, paused, waiting, verifying, completed, failed, cancelled, interrupted

        public var isActive: Bool { self == .running || self == .paused || self == .waiting || self == .verifying }
        public var isEnded: Bool { self == .completed || self == .failed || self == .cancelled || self == .interrupted }
    }

    public let id: UUID
    public let kind: FileOperationKind
    public let sources: [URL]
    public let destination: URL?
    public weak var originWindow: AnyObject?
    public internal(set) var incomingItem: FileItem?
    var incomingStartBytes: Int64 = 0
    public var incomingFraction: Double {
        guard let incomingItem else { return 0 }
        return incomingItem.size > 0 ? min(1, Double(max(0, (progress?.doneBytes ?? 0) - incomingStartBytes)) / Double(incomingItem.size)) : fraction
    }
    public internal(set) var state: State = .queued
    public internal(set) var progress: JobProgress?
    public internal(set) var rate = TransferRate()
    public internal(set) var errors: [String] = []
    public internal(set) var verification: CopyVerification.Result?
    public internal(set) var queuedAt = Date()
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    /// Sources that failed, for Retry.
    public internal(set) var failedSources: [URL] = []
    /// Why it can't pause (remote locations); nil when it can.
    public let pauseUnavailable: String?
    /// The job doing the work (nil for remote transfers, which have their own loop).
    public internal(set) var job: FileJob?
    /// Controls a remote transport; its work loop is owned by Services rather than FileJob.run().
    public internal(set) var controlJob: FileJob?
    var remoteRemaining: [URL] = []
    var remoteResults: [URL] = []
    public internal(set) var planJob: PlanJob?
    public internal(set) var planProgress: PlanProgress?
    var retryPlan: (() -> Void)?

    public var fraction: Double { planProgress?.fraction ?? progress?.fraction ?? 0 }
    /// Starts it (queued jobs wait for a free slot).
    var start: (() -> Void)?
    /// The journal kept while it runs, for resuming after a relaunch (local jobs).
    var journal: JobJournal?
    /// Where each completed top-level item went (for verification).
    var placed: [Int: URL] = [:]
    /// Copies and moves wait their turn; trashing, deleting and links start at once.
    public var isQueued: Bool { kind == .copy || kind == .move }

    init(kind: FileOperationKind, sources: [URL], destination: URL?, job: FileJob?, pauseUnavailable: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.job = job
        self.pauseUnavailable = pauseUnavailable
        progress = JobProgress(
            kind: kind, totalBytes: 0, doneBytes: 0, totalItems: sources.count, doneItems: 0, currentName: sources.first?.lastPathComponent ?? "",
            destination: destination)
    }

    public var canPause: Bool {
        pauseUnavailable == nil && (job != nil || controlJob != nil || planJob != nil) && (state == .running || state == .paused)
    }

    /// "Copying 3 items to Backup"
    public var title: String {
        if let planJob { return planJob.title }
        let n = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        let dest = destination.map { " to \($0.lastPathComponent)" } ?? ""
        return "\(kind.verb) \(n)\(dest)"
    }

    /// One line: speed, amounts and time left while running; the outcome once ended.
    public var statusText: String {
        if let planProgress, state == .running || state == .paused {
            let prefix = state == .paused ? "Paused — " : ""
            return "\(prefix)\(planProgress.completedSteps) of \(planProgress.totalSteps) steps — \(planProgress.currentTitle)"
        }
        let p = progress
        let amounts = p.map { $0.totalBytes > 0 ? "\(FileFormat.size($0.doneBytes)) of \(FileFormat.size($0.totalBytes))" : "" } ?? ""
        switch state {
        case .queued: return "Waiting for other operations to finish"
        case .paused: return ["Paused", amounts].filter { !$0.isEmpty }.joined(separator: " — ")
        case .waiting: return "Waiting for your answer"
        case .verifying: return "Verifying the copies…"
        case .running:
            if let p, p.phase == .preparing {
                return
                    "Preparing… \(p.totalFiles) \(p.totalFiles == 1 ? "file" : "files") · \(p.totalFolders) \(p.totalFolders == 1 ? "folder" : "folders") · \(FileFormat.size(p.totalBytes))"
            }
            var parts: [String] = []
            if let p, p.totalFiles > 0 { parts.append("\(p.doneFiles) of \(p.totalFiles) files") }
            if !amounts.isEmpty { parts.append(amounts) }
            if rate.hasSpeedEstimate { parts.append(rate.speedText) }
            if let p, p.totalBytes > 0 || p.totalFiles > 0 { parts.append(rate.timeLeftText) }
            return parts.joined(separator: " — ")
        case .completed:
            let base = errors.isEmpty ? "Done" : "Done, with \(errors.count) \(errors.count == 1 ? "error" : "errors")"
            var summary: [String] = []
            if let p, p.replacedItems > 0 { summary.append("Replaced \(p.replacedItems)") }
            if let p, p.skippedIdenticalItems > 0 { summary.append("Skipped \(p.skippedIdenticalItems) identical (\(comparisonMethodTitle))") }
            return [([base] + summary).joined(separator: " · "), verification?.summary].compactMap { $0 }.joined(separator: ". ")
        case .failed: return errors.first ?? "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted: it can be resumed next time Porpoise starts"
        }
    }

    public var comparisonMethodTitle: String {
        switch job?.comparisonOptions.method ?? controlJob?.comparisonOptions.method ?? .sizeAndDate {
        case .sizeAndDate: return "by size & date"
        case .sizeOnly: return "by size"
        case .content: return "by contents"
        }
    }

    var outcomeText: String {
        switch state {
        case .completed: return errors.isEmpty ? "Completed" : "Completed with errors"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        default: return state.rawValue
        }
    }
}

extension FileOperationsController {
    public static let activityChanged = Notification.Name("PorpoiseActivityChanged")
    /// Ended jobs kept in the list.
    static let endedKept = 200

    /// How many copies and moves run at once (Settings › Activity), at least one.
    public var concurrency: Int {
        get { max(1, Settings.shared.jobsConcurrency) }
        set {
            Settings.shared.jobsConcurrency = max(1, min(8, newValue))
            startQueued()
        }
    }

    func activityDidChange() { NotificationCenter.default.post(name: Self.activityChanged, object: self) }

    /// Adds `activity` and starts it now, or queues it behind the copies and moves already running.
    func enqueue(_ activity: Activity) {
        activities.append(activity)
        if let job = activity.job, activity.isQueued || activity.kind == .delete || activity.kind == .trash {
            var journal = JobJournal(id: activity.id, kind: activity.kind, sources: activity.sources, destination: activity.destination)
            // Items resumed from an earlier journal keep their partial copies.
            for (i, item) in journal.items.enumerated() {
                if let point = job.resumePoints[item.source] {
                    journal.items[i].staging = point.staging
                    journal.items[i].offset = point.offset
                }
            }
            activity.journal = journal
            journals.save(journal)
        }
        if !isInterrupting && (!activity.isQueued || runningQueued < concurrency) {
            activity.start?()
        }
        activityDidChange()
    }

    private var runningQueued: Int { activities.filter { $0.isQueued && $0.state.isActive }.count }

    /// Starts queued jobs while there are free slots, in the order of the list.
    func startQueued() {
        guard !isInterrupting else { return }
        for a in activities where a.state == .queued && runningQueued < concurrency { a.start?() }
        activityDidChange()
    }

    /// Marks it running and keeps its numbers current; the job thread's events go to its journal.
    func began(_ activity: Activity) {
        activity.state = .running
        activity.startedAt = Date()
        guard let job = activity.job else { return }
        job.onIncoming = { [weak activity] item, startBytes in
            DispatchQueue.main.async {
                activity?.incomingItem = item
                activity?.incomingStartBytes = startBytes
                // The following coalesced progress notification publishes this metadata too.
            }
        }
        let store = journals
        let id = activity.id
        job.onEvent = { [weak activity] e in
            store.record(e, id: id)
            if case .placed(let i, let target) = e { DispatchQueue.main.async { activity?.placed[i] = target } }
        }
    }

    func progressed(_ activity: Activity, _ p: JobProgress) {
        activity.progress = p
        if activity.state == .running && p.phase == .preparing { activity.rate.reset() }
        if activity.state == .running && p.phase == .transferring {
            activity.rate.add(
                bytes: p.doneBytes, at: ProcessInfo.processInfo.systemUptime, totalBytes: p.totalBytes, items: p.doneFiles, totalItems: p.totalFiles)
        }
        activityDidChange()
    }

    /// Ends it: history, journal, verification, then the next queued job.
    func ended(_ activity: Activity, errors: [String]) {
        let job = activity.job
        activity.incomingItem = nil
        activity.errors = errors
        if let job { activity.failedSources = job.failedSources }
        if job?.isInterrupted == true || activity.controlJob?.isInterrupted == true || activity.planJob?.isInterrupted == true {
            activity.state = .interrupted  // the journal stays, for next time
        } else {
            activity.journal.map { journals.remove($0.id) }
            if job?.isCancelled == true || activity.controlJob?.isCancelled == true || activity.planJob?.isCancelled == true {
                activity.state = .cancelled
                if let plan = activity.planJob { try? plan.store.remove(activity.id) }
            } else if !errors.isEmpty && (job?.results.isEmpty ?? activity.remoteResults.isEmpty) && activity.kind != .delete
                && activity.kind != .trash
            {
                activity.state = .failed
            } else {
                activity.state = .completed
            }
        }
        activity.finishedAt = Date()
        // The list keeps the latest ended jobs; the history keeps them all.
        let ended = activities.filter(\.state.isEnded)
        if ended.count > Self.endedKept {
            let drop = Set(ended.prefix(ended.count - Self.endedKept).map(\.id))
            activities.removeAll { drop.contains($0.id) }
        }
        if activity.state == .completed, activity.kind == .copy, Settings.shared.verifyCopies, !activity.placed.isEmpty,
            activity.sources.allSatisfy(\.isFileURL)
        {
            verify(activity)
        } else {
            record(activity)
        }
        startQueued()
    }

    /// Compares each copy with its original off the main thread, then records the result.
    private func verify(_ activity: Activity) {
        activity.state = .verifying
        let pairs = activity.placed.sorted { $0.key < $1.key }.map { (activity.sources[$0.key], $0.value) }
        DispatchQueue.global(qos: .utility).async {
            var total = CopyVerification.Result()
            for (src, copy) in pairs {
                let r = CopyVerification.verify(src, copy)
                total.files += r.files
                total.bytes += r.bytes
                total.mismatches += r.mismatches.map {
                    .init(path: copy.lastPathComponent + ($0.path.isEmpty ? "" : "/" + $0.path), reason: $0.reason)
                }
            }
            DispatchQueue.main.async {
                activity.verification = total
                activity.state = .completed
                self.record(activity)
                self.activityDidChange()
            }
        }
    }

    private func record(_ activity: Activity) {
        let seconds = (activity.finishedAt ?? Date()).timeIntervalSince(activity.startedAt ?? activity.queuedAt)
        history.append(
            HistoryEntry(
                date: activity.finishedAt ?? Date(), operation: activity.planJob == nil ? activity.kind.verb : activity.title,
                items: activity.planProgress?.totalSteps ?? activity.sources.count,
                sources: activity.sources.prefix(5).map(OperationHistory.describe), destination: activity.destination.map(OperationHistory.describe),
                bytes: activity.progress?.doneBytes ?? 0, seconds: seconds, outcome: activity.outcomeText, errors: Array(activity.errors.prefix(5)),
                verification: activity.verification?.summary))
        activityDidChange()
    }

    // MARK: What the Activity window does

    public func pause(_ activity: Activity) {
        guard activity.canPause else { return }
        activity.job?.pause()
        activity.controlJob?.pause()
        activity.planJob?.pause()
        activity.state = .paused
        activityDidChange()
    }

    public func resume(_ activity: Activity) {
        if activity.state == .cancelled { retry(activity, window: nil); return }
        guard activity.state == .paused else { return }
        activity.job?.resume()
        activity.controlJob?.resume()
        activity.planJob?.resume()
        activity.rate.reset()  // the pause isn't part of the speed
        activity.state = .running
        activityDidChange()
    }

    public func cancel(_ activity: Activity) {
        switch activity.state {
        case .queued:
            activities.removeAll { $0 === activity }
            if let plan = activity.planJob { try? plan.store.remove(activity.id) }
            activity.journal.map { journals.remove($0.id) }
            activityDidChange()
        default:
            activity.job?.cancel()
            activity.controlJob?.cancel()
            activity.planJob?.cancel()
            remoteCancel[activity.id]?()
        }
    }

    /// Moves a queued job earlier (negative) or later in the queue.
    public func move(_ activity: Activity, by offset: Int) {
        guard activity.state == .queued, let i = activities.firstIndex(where: { $0 === activity }) else { return }
        let queued = activities.indices.filter { activities[$0].state == .queued }
        guard let pos = queued.firstIndex(of: i) else { return }
        let to = queued[max(0, min(queued.count - 1, pos + offset))]
        activities.remove(at: i)
        activities.insert(activity, at: to)
        activityDidChange()
    }

    /// Runs the failed items again.
    public func retry(_ activity: Activity, window: AnyObject?) {
        if let retry = activity.retryPlan { retry(); return }
        let again: [URL]
        if activity.state == .cancelled || activity.state == .interrupted {
            again = activity.job?.remainingSources ?? activity.remoteRemaining
        } else {
            again = activity.failedSources.isEmpty ? activity.sources : activity.failedSources
        }
        activities.removeAll { $0 === activity }
        run(activity.kind, again, to: activity.destination, window: window, completedTransfers: activity.job?.completedTransfers ?? [:])
    }

    /// Removes the jobs that ended from the list (they stay in the history).
    public func clearEnded() {
        activities.removeAll { $0.state.isEnded }
        activityDidChange()
    }

    /// The app is quitting: running jobs stop where they are, keeping partial copies and journals so they can be
    /// resumed next time; queued ones keep their journals. Waits up to `timeout` for the jobs to stop.
    public func interruptAll(timeout: TimeInterval = 3) {
        isInterrupting = true
        let running = activities.filter { $0.state.isActive }
        for a in running {
            if let job = a.job, !job.hasEnded { job.interrupt() }
            if let plan = a.planJob, !plan.hasEnded { plan.interrupt() }
            if let remote = a.controlJob, !remote.hasEnded { remote.interrupt() }
        }
        let end = Date().addingTimeInterval(timeout)
        while running.contains(where: {
            ($0.job.map { !$0.hasEnded } ?? false) || ($0.controlJob.map { !$0.hasEnded } ?? false) || ($0.planJob.map { !$0.hasEnded } ?? false)
        }) && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
