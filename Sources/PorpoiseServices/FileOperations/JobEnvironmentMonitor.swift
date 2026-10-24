import Foundation
import Network
import PorpoiseCore

/// Automatic holds are independent of a user's Pause. A reconnect must never undo that choice.
/// Registering, unregistering and changing environment state must run on the main thread. Notice callbacks run
/// synchronously there; the reachability worker only snapshots availability before dispatching it to main.
/// Controls remain thread-safe, including hold cleanup when the monitor is released.
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
    private var pathMonitor: NWPathMonitor?

    /// Tests inject reachability and sleep events without changing the host's network or sleep state.
    init(monitorsNetwork: Bool = !Settings.isTesting) {
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
        pathMonitor?.cancel()
        for entry in registrations.values {
            entry.control?.setHold(.sleep, active: false)
            entry.control?.setHold(.network, active: false)
        }
    }

    func register(_ control: JobControl, network: Bool, changed: @escaping (String?) -> Void) {
        assert(Thread.isMainThread)
        registrations[ObjectIdentifier(control)] = Registration(control, network: network, changed: changed)
        apply()
    }

    func unregister(_ control: JobControl) {
        assert(Thread.isMainThread)
        registrations[ObjectIdentifier(control)] = nil
    }

    func setOnline(_ available: Bool) {
        assert(Thread.isMainThread)
        online = available; apply()
    }

    /// The app's workspace adapter delivers sleep/wake on main, before jobs are started.
    public func setSleeping(_ asleep: Bool) {
        assert(Thread.isMainThread)
        sleeping = asleep; apply()
    }

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
