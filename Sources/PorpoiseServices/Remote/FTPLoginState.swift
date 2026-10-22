import os

/// A login is one value: concurrent transfers must never combine a new user with the previous password.
/// Immutable snapshots leave the lock before config formatting, credential storage or any UI is called.
final class FTPLoginState: Sendable {
    struct Snapshot: Sendable, Equatable {
        let user: String?
        let password: String?
    }
    private let state: OSAllocatedUnfairLock<Snapshot>
    init(user: String?, password: String?) { state = OSAllocatedUnfairLock(initialState: Snapshot(user: user, password: password)) }
    var snapshot: Snapshot { state.withLock { $0 } }
    func replace(user: String, password: String) { state.withLock { $0 = Snapshot(user: user, password: password) } }
}
