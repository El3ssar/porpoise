import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Holds one real fake-server response until the test releases it, even after cancellation.
final class CloudBackendRequestGate: @unchecked Sendable {
    private let matches: @Sendable (URLRequest) -> Bool
    private let count = Locked(0)
    private let release = Locked<Callback<Void>?>(nil)
    let cancelled = Flag()
    init(matches: @escaping @Sendable (URLRequest) -> Bool) { self.matches = matches }
    var waiting: Bool { release.value != nil }
    func resume() { release.value?.resume() }
    var http: CloudHTTPTransport {
        CloudHTTPTransport(send: { [self] request in
            let response = try await CloudHTTPTransport().response(request)
            guard matches(request),
                count.change({
                    $0 += 1; return $0
                }) == 1
            else { return response }
            try await withTaskCancellationHandler {
                try await awaitCallback { callback in release.change { $0 = callback } }
            } onCancel: {
                cancelled.set()
            }
            return response
        })
    }
}

@MainActor @Suite struct CloudBackendReconciliationTests {
    private struct Account { let id: UUID; let scope: String }
    private final class Client {}

    @Test func removesBeforeInstallingAndPreservesUnchangedOrMissingClients() {
        let removed = UUID(), same = UUID(), replaced = UUID(), missing = UUID(), added = UUID()
        let sameClient = Client(), oldClient = Client(), newClient = Client(), missingClient = Client(), addedClient = Client()
        var current = [removed: Client(), same: sameClient, replaced: oldClient, missing: missingClient]
        let available = [same: sameClient, replaced: newClient, added: addedClient]
        let accounts = [same, replaced, missing, added].map { Account(id: $0, scope: $0.uuidString) }
        var events: [UUID] = [], installedScopes: [String] = []
        reconcileCloudProviders(
            accounts, id: \.id, installedIDs: Array(current.keys), client: { available[$0] }, currentClient: { current[$0] },
            remove: { id in
                events.append(id); current[id] = nil
            },
            install: { account, client in
                events.append(account.id); installedScopes.append(account.scope); current[account.id] = client
            })
        #expect(events == [removed, replaced, added])
        #expect(installedScopes == [replaced.uuidString, added.uuidString])
        #expect(current[same] === sameClient && current[missing] === missingClient)
        #expect(current[replaced] === newClient && current[added] === addedClient)
    }

    @Test func repeatedAccountUsesTheClientInstalledByThePreviousCallback() {
        let id = UUID(), client = Client()
        var current: Client?, scopes: [String] = []
        reconcileCloudProviders(
            [Account(id: id, scope: "first"), Account(id: id, scope: "second")], id: \.id, installedIDs: [],
            client: { _ in client }, currentClient: { _ in current }, remove: { _ in Issue.record("No stale account") },
            install: { account, candidate in
                scopes.append(account.scope); current = candidate
            })
        #expect(scopes == ["first"] && current === client)
    }
}
