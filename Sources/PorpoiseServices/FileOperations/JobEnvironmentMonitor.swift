import AppKit
import Foundation
import Network
import PorpoiseCore

/// Automatic holds are independent of a user's Pause. A reconnect must never undo that choice.
/// All registrations and notifications are serialized on main; controls remain thread-safe.
public final class JobEnvironmentMonitor {
    public static let shared = JobEnvironmentMonitor()
    private final class Registration {
        weak var control: JobControl?
        let network: Bool
        let changed: (String?) -> Void
        init(_ control: JobControl, network: Bool, changed: @escaping (String?) -> Void) {
            self.control = control; self.network = network; self.changed = changed
        }
    }
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var sleeping = false
    private var online = true
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?

    /// Inject a notification center and reachability events in tests; never change the host's network or sleep state.
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter, monitorsNetwork: Bool = !Settings.isTesting) {
        self.center = center
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.sleeping = asleep; self?.apply()
                })
        }
        if monitorsNetwork {
            let monitor = NWPathMonitor()
            pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                DispatchQueue.main.async { self?.setOnline(available) }
            }
            monitor.start(queue: DispatchQueue(label: "porpoise.jobs.reachability"))
        }
    }

    deinit {
        observers.forEach(center.removeObserver)
        pathMonitor?.cancel()
        for entry in registrations.values {
            entry.control?.setHold(.sleep, active: false)
            entry.control?.setHold(.network, active: false)
        }
    }

    func register(_ control: JobControl, network: Bool, changed: @escaping (String?) -> Void) {
        registrations[ObjectIdentifier(control)] = Registration(control, network: network, changed: changed)
        apply()
    }

    func unregister(_ control: JobControl) { registrations[ObjectIdentifier(control)] = nil }

    func setOnline(_ available: Bool) { online = available; apply() }

    private func apply() {
        registrations = registrations.filter { $0.value.control != nil && $0.value.control?.hasEnded == false }
        for entry in registrations.values {
            guard let control = entry.control else { continue }
            control.setHold(.sleep, active: sleeping)
            control.setHold(.network, active: entry.network && !online)
            entry.changed(sleeping ? "Waiting for wake" : entry.network && !online ? "Waiting for network" : nil)
        }
    }
}
