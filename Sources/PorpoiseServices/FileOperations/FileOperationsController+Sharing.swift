import Foundation
import PorpoiseCore

extension FileOperationsController {
    /// Stage a complete selection before the app offers it to a sharing service. Cancellation never shares a subset.
    @MainActor public func prepareForSharing(_ urls: [URL], window: AnyObject? = nil) async throws -> PreparedSharingItems {
        guard SharingPreparation.supports(urls) else { throw SharingPreparationError.unsupported }
        guard urls.contains(where: { !$0.isFileURL }) else { return PreparedSharingItems(urls: urls) }
        let policy = Settings.shared.transferPolicy
        // Explicitly selected files must not disappear because of a copy-job exclusion rule.
        let control = JobControl(policy: TransferPolicy(bytesPerSecond: policy.bytesPerSecond, retries: policy.retries, backoff: policy.backoff))
        let activity = Activity(kind: .copy, sources: urls, destination: nil, job: nil, control: control)
        activity.cloudTitle = "Preparing to share"
        activity.originWindow = window
        monitorEnvironment(activity)
        remoteCancel[activity.id] = { control.cancel() }
        activities.append(activity)
        began(activity)
        ui?.jobStarted(activity)
        activityDidChange()
        defer { control.finish(); remoteCancel.removeValue(forKey: activity.id); ui?.jobFinished(activity) }
        do {
            let prepared = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PreparedSharingItems, Error>) in
                    DispatchQueue(label: "porpoise.sharing-preparation", qos: .userInitiated).async {
                        do {
                            let result = try SharingPreparation.prepare(
                                urls, control: control, batchID: activity.id,
                                progress: { [weak self, weak activity] snapshot in
                                    DispatchQueue.main.async {
                                        guard let self, let activity, !activity.state.isEnded else { return }
                                        self.progressed(activity, snapshot)
                                        self.ui?.jobProgressed(activity, snapshot)
                                    }
                                },
                                notice: { [weak self, weak activity] notice in
                                    DispatchQueue.main.async {
                                        activity?.notice = notice; self?.activityDidChange()
                                    }
                                })
                            continuation.resume(returning: result)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: {
                control.cancel()
            }
            do { try Task.checkCancellation(); try await control.checkpointAsync() } catch { prepared.cleanup(); throw error }
            activity.remoteResults = prepared.urls
            if var progress = activity.progress {
                progress.doneBytes = progress.totalBytes; progress.doneItems = urls.count
                progressed(activity, progress)
            }
            ended(activity, errors: [])
            return prepared
        } catch {
            if error is CancellationError { control.cancel() }
            ended(activity, errors: control.isCancelled ? [] : [error.localizedDescription], cause: error)
            if control.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
