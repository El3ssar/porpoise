import AppKit
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite struct WorkspaceServiceEventsTests {
    private final class State {
        var sleeping: [Bool] = []
    }

    @Test func sleepAndWakeAreDeliveredSynchronouslyOnMain() {
        let center = NotificationCenter(), state = State()
        let events = WorkspaceServiceEvents(workspace: center, distributed: NotificationCenter(), authorizationInvalidated: {}) { asleep in
            #expect(Thread.isMainThread)
            state.sleeping.append(asleep)
        }
        withExtendedLifetime(events) {
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(state.sleeping == [true])
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            #expect(state.sleeping == [true, false])
        }
    }

    @Test func releasingTheAdapterRemovesItsObservers() {
        let center = NotificationCenter(), state = State()
        var events: WorkspaceServiceEvents? = WorkspaceServiceEvents(
            workspace: center, distributed: NotificationCenter(), authorizationInvalidated: {}
        ) { state.sleeping.append($0) }
        weak var released: WorkspaceServiceEvents?
        released = events
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(state.sleeping == [true])
        events = nil
        #expect(released == nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(state.sleeping == [true])
    }

    @Test(arguments: [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification])
    func leavingTheMacInvalidatesAuthorizationSynchronously(_ name: Notification.Name) {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), invalidations = Locked(0)
        let events = WorkspaceServiceEvents(
            workspace: workspace, distributed: distributed, authorizationInvalidated: { invalidations.change { $0 += 1 } },
            sleepingChanged: { _ in })
        withExtendedLifetime(events) {
            workspace.post(name: name, object: nil)
            #expect(invalidations.value == 1)
            distributed.post(name: name, object: nil)
            #expect(invalidations.value == 1)
        }
    }

    @Test func screenLockInvalidatesOnThePostingThreadWithoutWaitingForMain() async {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), invalidations = Locked(0)
        let events = WorkspaceServiceEvents(
            workspace: workspace, distributed: distributed, authorizationInvalidated: { invalidations.change { $0 += 1 } },
            sleepingChanged: { _ in })
        let count: Int = await withCheckedContinuation { continuation in
            DispatchQueue(label: "porpoise.tests.workspace-lock").async {
                #expect(!Thread.isMainThread)
                distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
                continuation.resume(returning: invalidations.value)
            }
        }
        withExtendedLifetime(events) { #expect(count == 1) }
    }

    @Test func releasingTheAdapterRemovesAuthorizationObserversFromBothCenters() {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), invalidations = Locked(0)
        var events: WorkspaceServiceEvents? = WorkspaceServiceEvents(
            workspace: workspace, distributed: distributed, authorizationInvalidated: { invalidations.change { $0 += 1 } },
            sleepingChanged: { _ in })
        weak var released: WorkspaceServiceEvents?
        released = events
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(invalidations.value == 1)
        events = nil
        #expect(released == nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(invalidations.value == 1)
    }
}
