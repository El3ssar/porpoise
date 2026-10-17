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
        let control = FileJob(kind: .copy, sources: sources, destinationFolder: nil)
        let activity = Activity(
            kind: .copy, sources: sources, destination: nil, job: nil, pauseUnavailable: item == nil ? nil : "Opening a remote file")
        activity.controlJob = control
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
        let context = CloudTransferContext(
            checkpoint: {
                while control.isPaused { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(40)) }
                try Task.checkCancellation()
                if control.isCancelled || control.isInterrupted { throw CancellationError() }
            },
            progress: { [weak self, weak activity] bytes, total in
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
                    self.ui?.jobProgressed(control, progress)
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
                do { return try await load(context) } catch CloudContentError.lowSpace where item == nil {
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
        ui?.jobStarted(control)
        activityDidChange()
        defer { control.finishExternal(); remoteCancel.removeValue(forKey: activity.id); ui?.jobFinished(control) }
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
        let pending = lock.withLock {
            let all = Array(waiters.values); waiters.removeAll(); return all
        }
        for continuation in pending { continuation.resume() }
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
