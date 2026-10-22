import AppKit

/// Whoever draws a thumbnail. Work for it is wanted only while it still shows the item: a list scrolled away,
/// closed, or showing another folder no longer does, and its work is dropped or cancelled.
protocol ThumbnailOwner: AnyObject {
    func showsThumbnail(of url: URL) -> Bool
}

/// The one owner of outstanding thumbnail work. Each kind runs a few at a time, waiting work is bounded (the oldest
/// goes first; it's asked for again when it's drawn again), and work for items no longer shown is dropped before it
/// starts or cancelled while it runs. Main thread only, like `Thumbnails`.
final class ThumbnailWorkScheduler {
    enum Lane: CaseIterable {
        /// Quick Look and audio artwork, from a local file (or a downloaded copy).
        case preview
        /// ffmpeg frames of videos Quick Look can't read: a process each.
        case video
        /// A cloud service's own thumbnail: a request to its API.
        case cloud
        /// A server's file copied here, one at a time: a folder of photos must not open dozens of connections.
        case server
    }

    struct Limits {
        var active: [Lane: Int] = [.preview: 8, .video: 2, .cloud: 4, .server: 1]
        /// Enough for a screen of tiny icons that are all folder previews (eight files each); bookkeeping only.
        var pending = 1024
    }

    /// Who wants a job: an owner showing `url` (a folder, for the files its preview is made from), or no one in
    /// particular (the Information panel), which always wants it.
    struct Interest {
        weak var owner: ThumbnailOwner?
        let url: URL
        let always: Bool
        init(owner: ThumbnailOwner?, url: URL) { self.owner = owner; self.url = url; always = owner == nil }
        var isWanted: Bool { always || owner?.showsThumbnail(of: url) == true }
    }

    /// One piece of work. Its body starts it and calls `finish()` on the main thread when it's over, cancelled or
    /// not: the lane's slot stays taken until then, so the bound holds for work that can't stop at once.
    final class Job {
        let key: String
        let lane: Lane
        fileprivate var interests: [Interest]
        fileprivate let body: (Job) -> Void
        fileprivate let dropped: () -> Void
        /// Handed on from another lane: started before newer work and dropped last.
        fileprivate let isContinuation: Bool
        fileprivate weak var scheduler: ThumbnailWorkScheduler?
        fileprivate var cancelHandler: (() -> Void)?
        private var cancelled = false

        /// Cancelled, or no owner shows the item any more (asked again when the result is about to be published, so
        /// nothing stale is shown however long ago the last sweep was).
        var isCancelled: Bool {
            if !cancelled && !isWanted { cancel() }
            return cancelled
        }

        fileprivate init(
            key: String, lane: Lane, interests: [Interest], isContinuation: Bool, body: @escaping (Job) -> Void,
            dropped: @escaping () -> Void
        ) {
            self.key = key; self.lane = lane; self.interests = interests; self.isContinuation = isContinuation
            self.body = body; self.dropped = dropped
        }

        fileprivate var isWanted: Bool { interests.contains { $0.isWanted } }

        /// What stops the running work: a Quick Look request, a process, a task.
        func onCancel(_ handler: @escaping () -> Void) {
            if cancelled { handler() } else { cancelHandler = handler }
        }

        fileprivate func cancel() {
            guard !cancelled else { return }
            cancelled = true
            cancelHandler?()
            cancelHandler = nil
        }

        func finish() { scheduler?.finished(self) }
    }

    /// Set from the main thread, read by the worker running a job.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    let limits: Limits
    private var pending: [Job] = []
    private var running: [Lane: [Job]] = [:]
    private var jobs: [String: Job] = [:]
    private var reconcileScheduled = false

    init(limits: Limits = Limits()) { self.limits = limits }

    var pendingCount: Int { pending.count }
    func runningCount(_ lane: Lane) -> Int { running[lane]?.count ?? 0 }

    /// Queues `body` for `key` unless it's already queued or running (then `interest` joins it).
    func submit(_ key: String, lane: Lane, interest: Interest, body: @escaping (Job) -> Void, dropped: @escaping () -> Void) {
        if let job = jobs[key] {
            job.interests.append(interest)
            compactInterests(job)
        } else {
            enqueue(Job(key: key, lane: lane, interests: [interest], isContinuation: false, body: body, dropped: dropped))
            pump()
        }
        scheduleReconcile()
    }

    /// Another owner draws an item whose work is already queued or running.
    func touch(_ key: String, interest: Interest) {
        guard let job = jobs[key] else { return }
        job.interests.append(interest)
        compactInterests(job)
        scheduleReconcile()
    }

    /// Finishes `job` and queues its next step (a downloaded copy's preview, a video's ffmpeg frame) for the same
    /// owners, ahead of newer work.
    func hand(_ job: Job, to lane: Lane, body: @escaping (Job) -> Void, dropped: @escaping () -> Void) {
        let next = Job(key: job.key, lane: lane, interests: job.interests, isContinuation: true, body: body, dropped: dropped)
        finished(job, pumping: false)
        enqueue(next)
        pump()
    }

    /// Drops waiting work and cancels running work no owner shows any more, then starts what fits.
    func reconcile() {
        reconcileScheduled = false
        for jobs in running.values { for job in jobs { _ = job.isCancelled } }
        let stale = pending.filter { !$0.isWanted }
        if !stale.isEmpty {
            pending.removeAll { !$0.isWanted }
            stale.forEach(drop)
        }
        pump()
    }

    private func enqueue(_ job: Job) {
        job.scheduler = self
        jobs[job.key] = job
        if job.isContinuation { pending.insert(job, at: pending.firstIndex { !$0.isContinuation } ?? pending.endIndex) } else { pending.append(job) }
        guard pending.count > limits.pending else { return }
        // Full: first what's no longer shown, then the oldest (asked for again when it's drawn again).
        let stale = pending.filter { !$0.isWanted }
        pending.removeAll { !$0.isWanted }
        stale.forEach(drop)
        while pending.count > limits.pending {
            drop(pending.remove(at: pending.firstIndex { !$0.isContinuation } ?? 0))
        }
    }

    private func drop(_ job: Job) {
        if jobs[job.key] === job { jobs[job.key] = nil }
        job.dropped()
    }

    /// Owners that went away, or repeated asks from the same one, don't pile up on a long-waiting job.
    private func compactInterests(_ job: Job) {
        guard job.interests.count > 4 else { return }
        var kept: [Interest] = []
        for i in job.interests where i.always || i.owner != nil {
            if !kept.contains(where: { $0.always == i.always && $0.owner === i.owner && $0.url == i.url }) { kept.append(i) }
        }
        job.interests = kept
    }

    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        // After the drawing pass that asked: by then the owner shows what it just drew.
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
    }

    private var pumping = false
    private var pumpAgain = false

    /// Starts waiting work while its lane has room. A job finishing at once (from its body) pumps again after.
    private func pump() {
        guard !pumping else {
            pumpAgain = true
            return
        }
        pumping = true
        defer { pumping = false }
        repeat {
            pumpAgain = false
            var i = 0
            while i < pending.count {
                let job = pending[i]
                guard job.isWanted else {
                    pending.remove(at: i)
                    drop(job)
                    continue
                }
                guard runningCount(job.lane) < limits.active[job.lane, default: 1] else {
                    i += 1
                    continue
                }
                pending.remove(at: i)
                running[job.lane, default: []].append(job)
                job.body(job)
                // The body may have queued its next step: look again from the front.
                i = 0
            }
        } while pumpAgain
    }

    fileprivate func finished(_ job: Job, pumping: Bool = true) {
        guard let i = running[job.lane]?.firstIndex(where: { $0 === job }) else { return }
        running[job.lane]?.remove(at: i)
        if jobs[job.key] === job { jobs[job.key] = nil }
        if pumping { pump() }
    }
}
