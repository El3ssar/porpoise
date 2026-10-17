import Foundation
import PorpoiseCore

extension FileOperationsController {
    @MainActor func downloadForOpening(_ item: FileItem, load: @escaping (CloudTransferContext) async throws -> URL) async throws -> URL {
        let control = FileJob(kind: .copy, sources: [item.url], destinationFolder: nil)
        let activity = Activity(kind: .copy, sources: [item.url], destination: nil, job: nil, pauseUnavailable: "Opening a remote file")
        activity.controlJob = control
        activity.openingName = item.name
        activity.retryTransfer = { RemoteOpener.open(item) }
        activity.incomingItem = item
        let context = CloudTransferContext(
            checkpoint: {
                try Task.checkCancellation(); try control.checkCancellation()
            },
            progress: { [weak self, weak activity] bytes, total in
                DispatchQueue.main.async {
                    guard let self, let activity, !activity.state.isEnded else { return }
                    let progress = JobProgress(
                        kind: .copy, totalBytes: total, doneBytes: bytes, totalItems: 1,
                        doneItems: bytes == total ? 1 : 0, currentName: item.name, destination: nil)
                    self.progressed(activity, progress)
                    self.ui?.jobProgressed(control, progress)
                }
            },
            status: { [weak self, weak activity] message in
                DispatchQueue.main.async {
                    activity?.notice = message; self?.activityDidChange()
                }
            })
        let task = Task { try await load(context) }
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
            activity.remoteResults = [local]
            if var progress = activity.progress {
                progress.doneBytes = progress.totalBytes
                progress.doneItems = progress.totalItems
                progressed(activity, progress)
            }
            ended(activity, errors: [])
            return local
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { control.cancel() }
            ended(activity, errors: control.isCancelled ? [] : [error.localizedDescription])
            if !control.isCancelled { ui?.showTransferErrors(activity, window: activity.originWindow) }
            throw error
        }
    }
}
