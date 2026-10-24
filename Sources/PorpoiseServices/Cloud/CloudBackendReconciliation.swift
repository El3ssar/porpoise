import Foundation

/// Synchronous main-actor bookkeeping only. Adapters own provider construction, registration and callbacks.
@MainActor func reconcileCloudProviders<Account, Client: AnyObject>(
    _ accounts: [Account], id: KeyPath<Account, UUID>, installedIDs: [UUID],
    client: @MainActor (UUID) -> Client?, currentClient: @MainActor (UUID) -> Client?,
    remove: @MainActor (UUID) -> Void, install: @MainActor (Account, Client) -> Void
) {
    let live = Set(accounts.map { $0[keyPath: id] })
    for id in installedIDs where !live.contains(id) { remove(id) }
    for account in accounts {
        let id = account[keyPath: id]
        guard let candidate = client(id), currentClient(id) !== candidate else { continue }
        install(account, candidate)
    }
}
