import Foundation
import PorpoiseCore

extension FileOperationsController {
    /// Visible immediately, but owns no filesystem job until the app's native confirmation succeeds.
    public func queueAutomation(_ kind: FileOperationKind, sources: [URL], destination: URL, window: AnyObject?) -> Activity {
        let pending = Activity(kind: kind, sources: sources, destination: destination, job: nil)
        pending.originWindow = window
        pending.allowsAuthorization = false
        pending.awaitingAutomationApproval = true
        pending.state = .waiting
        pending.notice = "Awaiting approval in Porpoise"
        activities.append(pending)
        activityDidChange()
        return pending
    }

    /// Neither the wire protocol nor the CLI can call this; the app supplies the native approval result.
    public func finishAutomationApproval(_ pending: Activity, approved: Bool) {
        guard pending.awaitingAutomationApproval, activities.contains(where: { $0 === pending }) else { return }
        pending.awaitingAutomationApproval = false
        activities.removeAll { $0 === pending }
        startQueued()
        guard approved, !pending.control.isCancelled, !pending.control.isInterrupted, !isInterrupting else { return }
        run(pending.kind, pending.sources, to: pending.destination, window: pending.originWindow, allowAuthorization: false)
    }
}
