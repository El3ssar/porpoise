import Foundation
import Network

/// Retires shared SSH connections after a sleep or a network change, so the next command connects afresh instead of
/// waiting for a dead one to time out; commands still running on a working one finish there. Commands cut off by a
/// connection that broke are retried by their provider (ReconnectPolicy), so jobs carry on.
public final class ConnectionMonitor: @unchecked Sendable {
    public static let shared = ConnectionMonitor()

    private let queue = DispatchQueue(label: "porpoise.connection-monitor")
    private var monitor: NWPathMonitor?
    /// The interfaces of the last satisfied path; a different set means the old connections went over a network
    /// that is no longer the one in use.
    private var lastInterfaces: [String]?
    /// What is done when connections should be dropped (tests count instead).
    let drop: () -> Void

    init(drop: @escaping () -> Void = { RemoteFS.retireSharedConnections() }) { self.drop = drop }

    /// Starts watching the network (once; the app calls it at launch).
    public func start() {
        queue.async { [weak self] in
            guard let self, self.monitor == nil else { return }
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                self?.pathChanged(satisfied: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name))
            }
            m.start(queue: self.queue)
            self.monitor = m
        }
    }

    /// The Mac woke from sleep: every shared connection is presumed dead.
    public func systemDidWake() {
        queue.async { self.drop() }
    }

    /// On the monitor's queue. The first path is only recorded; afterwards connections are dropped when the network
    /// comes back or the interfaces in use change.
    func pathChanged(satisfied: Bool, interfaces: [String]) {
        guard satisfied else {
            if lastInterfaces != nil { lastInterfaces = [] }
            return
        }
        defer { lastInterfaces = interfaces }
        guard let last = lastInterfaces, last != interfaces else { return }
        drop()
    }
}
