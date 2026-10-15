import Foundation
import PorpoiseCore

extension FileOperationsController {
    func runRemote(
        _ kind: FileOperationKind, _ urls: [URL], to folder: URL?, window: AnyObject?, done: (([URL]) -> Void)?,
        completed: [URL: URL] = [:], rule: TransferConflictRule? = nil, options: SyncCompareOptions? = nil
    ) {
        let control = FileJob(kind: kind, sources: urls, destinationFolder: folder)
        let runtime = RemoteTransferJob(
            kind: kind, sources: urls, destination: folder, control: control,
            rule: rule ?? Settings.shared.transferConflictRule,
            options: options ?? SyncCompareOptions(method: Settings.shared.transferCompareMethod), completed: completed)
        let activity = Activity(kind: kind, sources: urls, destination: folder, job: nil)
        activity.controlJob = control
        activity.remoteRemaining = urls
        runtime.onProgress = { [weak self, weak activity] snapshot in
            DispatchQueue.main.async {
                self?.ui?.jobProgressed(control, snapshot)
                if let activity { self?.progressed(activity, snapshot) }
            }
        }
        runtime.resolve = { [weak self, weak activity] info in
            var answer = ConflictAnswer(.cancel)
            DispatchQueue.main.sync {
                activity?.state = .waiting
                self?.activityDidChange()
                answer = self?.ui?.resolveConflict(info, kind: kind) ?? .init(.cancel)
                activity?.rate.reset()
                activity?.state = control.isPaused ? .paused : .running
                self?.activityDidChange()
            }
            return answer
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
                    activity.remoteRemaining = runtime.remaining
                    activity.remoteResults = runtime.results
                    activity.failedSources = runtime.failedSources
                    self.ui?.jobFinished(control)
                    self.ended(activity, errors: runtime.errors)
                    Self.notifyChanged(urls + (folder.map { [$0] } ?? []) + runtime.results)
                    if !runtime.errors.isEmpty && !control.isCancelled { self.showErrors(runtime.errors, window: window) }
                    done?(runtime.results)
                }
            }
        }
        enqueue(activity)
    }
}
