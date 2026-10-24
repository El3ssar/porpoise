import AppKit
import PorpoiseServices

/// Owns the macOS event subscriptions; services receive only the policy inputs they need.
final class WorkspaceServiceEvents {
    @MainActor static let shared = WorkspaceServiceEvents(
        workspace: NSWorkspace.shared.notificationCenter,
        distributed: DistributedNotificationCenter.default(),
        authorizationInvalidated: { PrivilegedHelper.forgetAuthorization() },
        sleepingChanged: { JobEnvironmentMonitor.shared.setSleeping($0) })

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        workspace: NotificationCenter, distributed: NotificationCenter,
        authorizationInvalidated: @escaping @Sendable () -> Void,
        sleepingChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(
                (
                    workspace,
                    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                        MainActor.assumeIsolated { sleepingChanged(asleep) }
                    }
                ))
        }
        // Authorization invalidation must not wait for main: the notification's posting thread drops it at once.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(
                (workspace, workspace.addObserver(forName: name, object: nil, queue: nil) { _ in authorizationInvalidated() }))
        }
        observers.append(
            (
                distributed,
                distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
                    authorizationInvalidated()
                }
            ))
    }

    deinit { for (center, observer) in observers { center.removeObserver(observer) } }
}
