import Foundation
import PorpoiseCore

extension FileOperationsController {
    @MainActor func downloadForOpening(_ item: FileItem, load: @escaping (CloudTransferContext) async throws -> URL) async throws -> URL {
        let result = try await cloudTask(title: "Opening “\(item.name)”", sources: [item.url], opening: item) { context in
            [try await load(context)]
        }
        return result[0]
    }

    @MainActor func cloudTask(
        title: String, sources: [URL], opening item: FileItem? = nil, quiet: Bool = false,
        load: @escaping (CloudTransferContext) async throws -> [URL]
    ) async throws -> [URL] {
        let control = JobControl(policy: Settings.shared.transferPolicy)
        let budget = TransferByteBudget()
        let activity = Activity(
            kind: .copy, sources: sources, destination: nil, job: nil, control: control, pauseUnavailable: item == nil ? nil : "Opening a remote file"
        )
        activity.cloudTitle = title
        if let item {
            activity.openingName = item.name
            activity.retryTransfer = { RemoteOpener.open(item) }
            activity.incomingItem = item
        } else {
            activity.retryTransfer = { [weak self] in
                Task { _ = try? await self?.cloudTask(title: title, sources: sources, quiet: quiet, load: load) }
            }
        }
        monitorEnvironment(activity)
        let context = CloudTransferContext(
            checkpoint: {
                try await control.checkpointAsync()
                try await control.throttleAsync(bytes: budget.takePending())
            },
            progress: { [weak self, weak activity] bytes, total in
                _ = budget.add(cumulative: bytes)
                DispatchQueue.main.async {
                    guard let self, let activity, !activity.state.isEnded else { return }
                    var progress = JobProgress(
                        kind: .copy, totalBytes: total, doneBytes: bytes, totalItems: 1,
                        doneItems: bytes == total ? 1 : 0, currentName: item?.name ?? title, destination: nil)
                    if item == nil, let prior = activity.progress {
                        progress.totalItems = prior.totalItems; progress.doneItems = prior.doneItems
                        progress.totalFiles = prior.totalFiles; progress.doneFiles = prior.doneFiles
                    }
                    self.progressed(activity, progress)
                    self.ui?.jobProgressed(activity, progress)
                }
            },
            items: { [weak self, weak activity] done, total in
                DispatchQueue.main.async {
                    guard let self, let activity, !activity.state.isEnded, var progress = activity.progress else { return }
                    progress.totalItems = total; progress.doneItems = done
                    progress.totalFiles = total; progress.doneFiles = done
                    self.progressed(activity, progress)
                }
            },
            status: { [weak self, weak activity] message in
                DispatchQueue.main.async {
                    activity?.notice = message; self?.activityDidChange()
                }
            })
        let wake = CloudTransferWake()
        activity.resumeCloudTask = { wake.signal() }
        let observer = NotificationCenter.default.addObserver(forName: CloudOffline.spaceChanged, object: nil, queue: nil) { _ in wake.signal() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let task = Task {
            while true {
                do {
                    try await context.checkpoint()
                    let result = try await load(context)
                    try await context.checkpoint()
                    return result
                } catch CloudContentError.lowSpace where item == nil {
                    activity.state = .paused; activity.notice = CloudContentError.lowSpace.localizedDescription
                    self.activityDidChange()
                    try await wake.wait()
                    activity.state = .running; activity.notice = nil; self.activityDidChange()
                }
            }
        }
        remoteCancel[activity.id] = {
            control.cancel(); task.cancel()
        }
        activities.append(activity)
        began(activity)
        ui?.jobStarted(activity)
        activityDidChange()
        defer { control.finish(); remoteCancel.removeValue(forKey: activity.id); ui?.jobFinished(activity) }
        do {
            let local = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            if control.isCancelled { throw CancellationError() }
            activity.remoteResults = local
            if var progress = activity.progress {
                progress.doneBytes = progress.totalBytes
                progress.doneItems = progress.totalItems; progress.doneFiles = progress.totalFiles
                progressed(activity, progress)
            }
            ended(activity, errors: [])
            if quiet { activities.removeAll { $0 === activity }; activityDidChange() }
            return local
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { control.cancel() }
            ended(activity, errors: control.isCancelled ? [] : [error.localizedDescription])
            if !control.isCancelled && !quiet { ui?.showTransferErrors(activity, window: activity.originWindow) }
            throw error
        }
    }
}

/// Event-driven retries after a disk-space pause, with a 60-second fallback and cancellation-safe teardown.
private final class CloudTransferWake: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pending = false
    func signal() {
        let waiting = lock.withLock {
            let all = Array(waiters.values); waiters.removeAll(); pending = all.isEmpty; return all
        }
        for continuation in waiting { continuation.resume() }
    }
    private func signal(_ id: UUID) { lock.withLock { waiters.removeValue(forKey: id) }?.resume() }
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                let ready = lock.withLock {
                    if pending { pending = false; return true }
                    waiters[id] = continuation; return false
                }
                if ready { continuation.resume(); return }
                if Task.isCancelled { signal(id) }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    self?.signal(id)
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            self.signal(id)
        }
    }
}
