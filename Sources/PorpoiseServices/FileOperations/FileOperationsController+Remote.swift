import Foundation
import PorpoiseCore

extension FileOperationsController {
    func runRemote(
        _ kind: FileOperationKind, _ urls: [URL], to folder: URL?, window: AnyObject?, done: (([URL]) -> Void)?,
        completed: [URL: URL] = [:], cloudOperations: [URL: UUID] = [:], cloudBatchID: UUID? = nil, rule: TransferConflictRule? = nil,
        options: TransferCompareOptions? = nil, moved: (([URL: URL]) -> Void)? = nil
    ) {
        let control = JobControl(policy: Settings.shared.transferPolicy)
        let runtime = RemoteTransferJob(
            kind: kind, sources: urls, destination: folder, control: control,
            rule: rule ?? Settings.shared.transferConflictRule,
            options: options ?? TransferCompareOptions(method: Settings.shared.transferCompareMethod), completed: completed)
        runtime.disposeReplacedItem = replacementDisposal
        runtime.cloudOperations = cloudOperations
        let activity = Activity(kind: kind, sources: urls, destination: folder, job: nil, control: control)
        runtime.cloudBatchID = cloudBatchID ?? activity.id
        activity.originWindow = window
        activity.remoteRemaining = urls
        runtime.onNotice = { [weak self, weak activity] notice in
            DispatchQueue.main.async {
                activity?.notice = notice
                self?.activityDidChange()
            }
        }
        runtime.onIncoming = { [weak activity] item in
            DispatchQueue.main.async {
                activity?.incomingItem = item
                activity?.incomingStartBytes = activity?.progress?.doneBytes ?? 0
            }
        }
        runtime.onNoSpace = { [weak self, weak activity] bytes in
            self?.awaitDiskSpace(bytes, activity: activity, job: control, window: window) ?? false
        }
        runtime.onProgress = { [weak self, weak activity] snapshot in
            DispatchQueue.main.async {
                if let activity { self?.ui?.jobProgressed(activity, snapshot) }
                if let activity { self?.progressed(activity, snapshot) }
            }
        }
        runtime.resolve = { [weak self, weak activity] info in
            self?.awaitConflict(info, kind: kind, activity: activity, job: control, window: window) ?? .init(.cancel)
        }
        activity.retryTransfer = { [weak self, weak activity] in
            guard let self, let activity else { return }
            let remaining = activity.state == .cancelled || activity.state == .interrupted ? runtime.remaining : runtime.failedSources
            self.activities.removeAll { $0 === activity }
            self.runRemote(
                kind, remaining, to: folder, window: window, done: done,
                completed: runtime.completed, cloudOperations: runtime.cloudOperations, cloudBatchID: runtime.cloudBatchID, rule: runtime.rule,
                options: runtime.options, moved: moved)
        }
        activity.start = { [weak self, weak activity] in
            guard let self, let activity, activity.state == .queued else { return }
            self.began(activity)
            TrashService.shared.record([])
            self.ui?.jobStarted(activity)
            DispatchQueue(label: "porpoise.remote-transfer." + activity.id.uuidString, qos: .userInitiated).async {
                runtime.run()
                TrashService.shared.flush()
                let submitted = Set(urls)
                let movedItems = runtime.movedItems.filter { submitted.contains($0.key) }
                DispatchQueue.main.async {
                    activity.remoteComparisonMethod = runtime.options.method
                    activity.remoteRemaining = runtime.remaining
                    activity.remoteResults = runtime.results
                    activity.failedSources = runtime.failedSources
                    self.ui?.jobFinished(activity)
                    self.ended(activity, errors: runtime.errors, cause: runtime.firstError, failures: runtime.failures)
                    Self.notifyChanged(urls + (folder.map { [$0] } ?? []) + runtime.results)
                    if !runtime.errors.isEmpty && !control.isCancelled { self.ui?.showTransferErrors(activity, window: window) }
                    moved?(movedItems)
                    done?(runtime.results)
                }
            }
        }
        enqueue(activity)
    }
}
