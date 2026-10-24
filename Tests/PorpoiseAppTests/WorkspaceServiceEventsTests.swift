import AppKit
import Testing

@testable import Porpoise

@MainActor @Suite struct WorkspaceServiceEventsTests {
    private final class State {
        var sleeping: [Bool] = []
    }

    @Test func sleepAndWakeAreDeliveredSynchronouslyOnMain() {
        let center = NotificationCenter(), state = State()
        let events = WorkspaceServiceEvents(workspace: center) { asleep in
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
        var events: WorkspaceServiceEvents? = WorkspaceServiceEvents(workspace: center) { state.sleeping.append($0) }
        weak var released = events
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(state.sleeping == [true])
        events = nil
        #expect(released == nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(state.sleeping == [true])
    }
}
