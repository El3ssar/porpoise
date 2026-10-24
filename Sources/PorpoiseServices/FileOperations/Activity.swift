import Foundation
import PorpoiseCore
import PorpoiseFileSystem

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
    /// Automation never gets administrator retries, including Activity Retry and journal recovery.
    public internal(set) var allowsAuthorization = true
    var awaitingAutomationApproval = false
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
    var failures: [TransferFailure] = []
    public var errorDetails: [TransferFailure] { failures.isEmpty ? errors.map { TransferFailure(source: nil, message: $0) } : failures }
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
    public let control: JobControl
    var verificationControl: JobControl?
    var verificationCancelled = false
    var remoteComparisonMethod: TransferCompareMethod = .sizeAndDate
    var remoteRemaining: [URL] = []
    var remoteResults: [URL] = []
    var retryTransfer: (() -> Void)?

    public var fraction: Double { progress?.fraction ?? 0 }
    /// Starts it (queued jobs wait for a free slot).
    var start: (() -> Void)?
    /// Whether a journal is kept while it runs (under its id), for resuming after a relaunch (local jobs).
    var isJournaled = false
    /// Where each completed top-level item went (for verification).
    var placed: [Int: URL] = [:]
    /// Copies and moves wait their turn; trashing, deleting and links start at once.
    public var isQueued: Bool { kind == .copy || kind == .move }

    init(
        kind: FileOperationKind, sources: [URL], destination: URL?, job: FileJob?, control: JobControl? = nil, pauseUnavailable: String? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.job = job
        self.control = control ?? job?.control ?? JobControl()
        self.pauseUnavailable = pauseUnavailable
        progress = JobProgress(
            kind: kind, totalBytes: 0, doneBytes: 0, totalItems: sources.count, doneItems: 0, currentName: sources.first.map(Self.name) ?? "",
            destination: destination)
    }

    public var canPause: Bool {
        pauseUnavailable == nil && (state == .running || state == .paused)
    }

    /// "Copying 3 items to Backup"
    var openingName: String?
    var cloudTitle: String?
    var resumeCloudTask: (() -> Void)?

    public var title: String { ActivityPresentation.title(of: self) }

    /// Cloud items have ids in their URLs: their names come from the listing ("Q3", "My Drive").
    public static func name(_ url: URL) -> String {
        PlacesModel.isCloud(url) ? RemoteFS.displayName(for: url) : url.lastPathComponent
    }

    /// A passing condition the transfer is handling by itself ("Slowed down by Google, retrying", "Waiting for
    /// network"): shown instead of the speed until it clears.
    public internal(set) var notice: String?
    var environmentNotice: String?

    /// One line: speed, amounts and time left while running; the outcome once ended.
    public var statusText: String { ActivityPresentation.status(of: self) }

    public var comparisonMethodTitle: String {
        switch job?.comparisonOptions.method ?? remoteComparisonMethod {
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

    func monitorEnvironment(_ activity: Activity) {
        environment.register(
            activity.control,
            network: (activity.sources + [activity.destination].compactMap { $0 }).contains { !$0.isFileURL && LocationKind.of($0) != .archive }
        ) {
            [weak self, weak activity] notice in
            activity?.environmentNotice = notice
            activity?.rate.reset()
            self?.activityDidChange()
        }
    }

    /// Adds `activity` and starts it now, or queues it behind the copies and moves already running.
    func enqueue(_ activity: Activity) {
        activities.append(activity)
        monitorEnvironment(activity)
        if let job = activity.job, activity.isQueued || activity.kind == .delete || activity.kind == .trash {
            // Looking at every source and writing the journal waits for nothing here: it happens on the journal's queue.
            let (id, kind, sources, destination) = (activity.id, activity.kind, activity.sources, activity.destination)
            let resumePoints = job.resumePoints
            let allowsAuthorization = activity.allowsAuthorization
            let created = Date()
            activity.isJournaled = true
            journals.begin {
                var journal = JobJournal(id: id, kind: kind, sources: sources, destination: destination)
                journal.created = created
                journal.allowsAuthorization = allowsAuthorization ? nil : false
                // Items resumed from an earlier journal keep their partial copies.
                for (i, item) in journal.items.enumerated() {
                    if let point = resumePoints[item.source] {
                        journal.items[i].staging = point.staging
                        journal.items[i].offset = point.offset
                    }
                }
                return journal
            }
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
        let stages = transferStages
        job.removalCheckpoint = { try stages.checkpoint($0) }
        job.publicationCheckpoint = { try stages.publicationCheckpoint($0) }
        let id = activity.id
        job.onEvent = { [weak activity] e in
            store.record(e, id: id)
            if case .placed(let i, let target) = e { DispatchQueue.main.async { activity?.placed[i] = target } }
        }
    }

    func progressed(_ activity: Activity, _ p: JobProgress) {
        activity.progress = p
        if activity.state == .running && p.phase != .transferring { activity.rate.reset() }
        if activity.state == .running && p.phase == .transferring {
            activity.rate.add(
                bytes: p.doneBytes, at: ProcessInfo.processInfo.systemUptime, totalBytes: p.totalBytes, items: p.doneFiles, totalItems: p.totalFiles)
        }
        activityDidChange()
    }

    /// Ends it: history, journal, verification, then the next queued job. `cause`: the first error behind `errors`,
    /// for the diagnostic event a failed copy or move records (its category only).
    func ended(_ activity: Activity, errors: [String], cause: Error? = nil, failures: [TransferFailure] = []) {
        environment.unregister(activity.control)
        activity.environmentNotice = nil
        let job = activity.job
        activity.incomingItem = nil
        activity.errors = errors
        activity.failures = activity.job?.failures ?? failures
        var pairedCounts: [String: Int] = [:]
        for failure in activity.failures {
            pairedCounts[failure.message, default: 0] += 1
        }
        let unpaired = errors.filter { message in
            guard let count = pairedCounts[message], count > 0 else { return true }
            pairedCounts[message] = count - 1; return false
        }
        activity.failures += unpaired.map { TransferFailure(source: nil, message: $0) }
        if let job { activity.failedSources = job.failedSources }
        if activity.control.isInterrupted {
            activity.state = .interrupted  // the journal stays, for next time
        } else {
            if activity.isJournaled { journals.remove(activity.id) }
            if activity.control.isCancelled {
                activity.state = .cancelled
            } else if !errors.isEmpty && (job?.results.isEmpty ?? activity.remoteResults.isEmpty) && activity.kind != .delete
                && activity.kind != .trash
            {
                activity.state = .failed
            } else {
                activity.state = .completed
            }
        }
        activity.finishedAt = Date()
        if !errors.isEmpty, activity.kind == .copy || activity.kind == .move, activity.state == .failed || activity.state == .completed {
            if let cause {
                Diagnostics.shared.record(.transferFailed, error: cause)
            } else {
                Diagnostics.shared.record(.transferFailed, failure: .unknown)
            }
        }
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
        activity.verificationCancelled = false
        let control = JobControl()
        activity.verificationControl = control
        let pairs = activity.placed.sorted { $0.key < $1.key }.map { (activity.sources[$0.key], $0.value) }
        DispatchQueue.global(qos: .utility).async {
            var total = CopyVerification.Result()
            for (src, copy) in pairs {
                if control.isCancelled { break }
                let r = CopyVerification.verify(src, copy, cancelled: { control.isCancelled })
                total.files += r.files
                total.bytes += r.bytes
                total.mismatches += r.mismatches.map {
                    .init(path: copy.lastPathComponent + ($0.path.isEmpty ? "" : "/" + $0.path), reason: $0.reason)
                }
            }
            control.finish()
            DispatchQueue.main.async {
                activity.verificationControl = nil
                activity.verificationCancelled = control.isCancelled
                activity.verification = control.isCancelled ? nil : total
                activity.state = control.isInterrupted ? .interrupted : control.isCancelled ? .cancelled : .completed
                self.record(activity)
                self.startQueued()
            }
        }
    }

    private func record(_ activity: Activity) {
        let seconds = (activity.finishedAt ?? Date()).timeIntervalSince(activity.startedAt ?? activity.queuedAt)
        let entry = HistoryEntry(
            date: activity.finishedAt ?? Date(), operation: activity.kind.verb,
            items: activity.sources.count,
            sources: activity.sources.prefix(5).map(OperationHistory.describe), destination: activity.destination.map(OperationHistory.describe),
            bytes: activity.progress?.doneBytes ?? 0, seconds: seconds, outcome: activity.outcomeText, errors: Array(activity.errors.prefix(5)),
            verification: activity.verification?.summary, transferNotes: activity.control.transferNotes)
        history.append(entry)
        activityDidChange()
    }

    // MARK: What the Activity window does

    public func pause(_ activity: Activity) {
        guard activity.canPause else { return }
        activity.control.pause()
        activity.state = .paused
        activityDidChange()
    }

    public func resume(_ activity: Activity) {
        if activity.state == .cancelled { retry(activity, window: nil); return }
        guard activity.state == .paused else { return }
        activity.control.resume()
        activity.resumeCloudTask?()
        activity.rate.reset()  // the pause isn't part of the speed
        activity.state = .running
        activityDidChange()
    }

    public func cancel(_ activity: Activity) {
        switch activity.state {
        case .queued:
            activities.removeAll { $0 === activity }
            if activity.isJournaled { journals.remove(activity.id) }
            activityDidChange()
        default:
            (activity.verificationControl ?? activity.control).cancel()
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
        guard !activity.awaitingAutomationApproval else { return }
        if activity.verificationCancelled {
            verify(activity)
            activityDidChange()
            return
        }
        if let retry = activity.retryTransfer { retry(); return }
        let again: [URL]
        if activity.state == .cancelled || activity.state == .interrupted {
            again = activity.job?.remainingSources ?? activity.remoteRemaining
        } else {
            again = activity.failedSources.isEmpty ? activity.sources : activity.failedSources
        }
        activities.removeAll { $0 === activity }
        run(
            activity.kind, again, to: activity.destination, window: window, allowAuthorization: activity.allowsAuthorization,
            completedTransfers: activity.job?.completedTransfers ?? [:])
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
            let control = a.verificationControl ?? a.control
            if !control.hasEnded { control.interrupt() }
            if a.awaitingAutomationApproval { control.finish() }
        }
        let end = Date().addingTimeInterval(timeout)
        while running.contains(where: {
            !($0.verificationControl ?? $0.control).hasEnded
        }) && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        // Every queued and interrupted job's journal, and every ended job's entry, is on disk before the app goes.
        journals.flush()
        history.flush()
        TrashService.shared.flush()
    }
}
