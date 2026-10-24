import AppKit
import PorpoiseServices

/// Owns the macOS event subscriptions; services receive only the policy inputs they need.
final class WorkspaceServiceEvents {
    @MainActor static let shared = WorkspaceServiceEvents(
        workspace: NSWorkspace.shared.notificationCenter,
        sleepingChanged: { JobEnvironmentMonitor.shared.setSleeping($0) })

    private let workspace: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(workspace: NotificationCenter, sleepingChanged: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.workspace = workspace
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { sleepingChanged(asleep) }
                })
        }
    }

    deinit { observers.forEach(workspace.removeObserver) }
}
