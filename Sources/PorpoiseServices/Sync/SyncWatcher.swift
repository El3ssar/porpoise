import Foundation

/// Events only request a fresh scan; they are never interpreted as authoritative deletions. Coalesces local
/// FSEvents and periodic remote/missing-volume probes. The owner serializes sync jobs and persists pair settings.
public final class SyncWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.porpoise.sync-watch", qos: .utility)
    private var events: IndexEvents?
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var paused = false
    private var stopped = false
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    public init(
        roots: [URL], debounce: TimeInterval = 2, pollInterval: TimeInterval = 30,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.debounce = max(0, debounce); self.onChange = onChange
        let local = roots.filter(\.isFileURL).map(\.path)
        if !local.isEmpty {
            events = IndexEvents(roots: local, since: 0) { [weak self] _, _, _ in self?.requestScan() }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(1, pollInterval), repeating: max(1, pollInterval))
        timer.setEventHandler { [weak self] in self?.schedule() }
        self.timer = timer; timer.resume()
    }
    public func requestScan() { queue.async { [weak self] in self?.schedule() } }
    /// Resuming requests a full scan, including changes made while paused.
    public func setPaused(_ value: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.paused = value
            self.pending?.cancel(); self.pending = nil
            if !value { self.schedule() }
        }
    }
    /// Explicit teardown stays on the watcher queue, including stopping the filesystem stream.
    public func stop() {
        queue.async { [self] in
            stopped = true; pending?.cancel(); pending = nil
            timer?.cancel(); timer = nil; events = nil
        }
    }
    private func schedule() {
        guard !paused, !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.paused, !self.stopped else { return }
            self.pending = nil; self.onChange()
        }
        pending = work; queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
    deinit { pending?.cancel(); timer?.cancel() }
}
