import Foundation
import PorpoiseCore

extension FileOperationsController {
    func runRemote(
        _ kind: FileOperationKind, _ urls: [URL], to folder: URL?, window: AnyObject?, done: (([URL]) -> Void)?,
        completed: [URL: URL] = [:], rule: TransferConflictRule? = nil, options: SyncCompareOptions? = nil
    ) {
        let control = FileJob(kind: kind, sources: urls, destinationFolder: folder)
        configureReplacementDisposal(control)
        let runtime = RemoteTransferJob(
            kind: kind, sources: urls, destination: folder, control: control,
            rule: rule ?? Settings.shared.transferConflictRule,
            options: options ?? SyncCompareOptions(method: Settings.shared.transferCompareMethod), completed: completed)
        let activity = Activity(kind: kind, sources: urls, destination: folder, job: nil)
        activity.originWindow = window
        activity.controlJob = control
        activity.remoteRemaining = urls
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
                self?.ui?.jobProgressed(control, snapshot)
                if let activity { self?.progressed(activity, snapshot) }
            }
        }
        runtime.resolve = { [weak self, weak activity] info in
            self?.awaitConflict(info, kind: kind, activity: activity, job: control, window: window) ?? .init(.cancel)
        }
        activity.retryPlan = { [weak self, weak activity] in
            guard let self, let activity else { return }
            let remaining = activity.state == .cancelled || activity.state == .interrupted ? runtime.remaining : runtime.failedSources
            self.activities.removeAll { $0 === activity }
            self.runRemote(
                kind, remaining, to: folder, window: window, done: done,
                completed: runtime.completed, rule: runtime.rule, options: runtime.options)
        }
        activity.start = { [weak self, weak activity] in
            guard let self, let activity, activity.state == .queued else { return }
            self.began(activity)
            self.ui?.jobStarted(control)
            DispatchQueue.global(qos: .userInitiated).async {
                runtime.run()
                DispatchQueue.main.async {
                    control.comparisonOptions = runtime.options
                    activity.remoteRemaining = runtime.remaining
                    activity.remoteResults = runtime.results
                    activity.failedSources = runtime.failedSources
                    self.ui?.jobFinished(control)
                    self.ended(activity, errors: runtime.errors)
                    Self.notifyChanged(urls + (folder.map { [$0] } ?? []) + runtime.results)
                    if !runtime.errors.isEmpty && !control.isCancelled { self.ui?.showTransferErrors(activity, window: window) }
                    done?(runtime.results)
                }
            }
        }
        enqueue(activity)
    }
}
