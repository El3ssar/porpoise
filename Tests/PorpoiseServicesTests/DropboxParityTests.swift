import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Dropbox accounts and transfers behave as Drive's do: sign-in state, the account a refusal names, pausing, blocking
/// calls and signing out.
@Suite(.serialized, .isolatedSettings) struct DropboxParityTests {
    @MainActor private final class Fixture {
        let server: FakeDropboxServer
        let suite = "porpoise-dropbox-parity-" + UUID().uuidString
        let store: DropboxAccountStore
        let backend: DropboxCloudBackend
        let accounts = CloudAccounts()
        init() throws {
            Settings.store.set("fixture-app", forKey: "dropboxAppKey")
            server = try FakeDropboxServer()
            store = DropboxAccountStore(
                defaults: UserDefaults(suiteName: suite)!, credentials: MemoryCredentials(), configuration: server.config,
                directory: server.directory)
            backend = DropboxCloudBackend(store: store)
            accounts.backend = CompositeCloudBackend([.dropbox: backend])
        }
        func connect() async throws -> Result<CloudAccount, CloudConnectError> {
            try await awaitCallback { continuation in
                _ = accounts.connect(
                    .dropbox, openBrowser: openInFakeBrowser,
                    done: { continuation.resume(returning: $0) })
            }
        }
        func cleanup() {
            backend.setActive(false)
            for account in store.accounts { RemoteFS.registerCloud(nil, for: DropboxLocation(accountID: account.id).url) }
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    // B2: once Dropbox says to sign in again, a re-check scheduled before can't call the account OK.
    @Test @MainActor func signInNeededStaysUntilSignedInAgain() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect().get()
        let id = try #require(fixture.store.accounts.first?.id)
        // A connection failure leaves a re-check scheduled; then Dropbox refuses the sign-in.
        fixture.store.status.record(id, URLError(.notConnectedToInternet))
        fixture.store.status.record(id, DropboxError.reconnect, signInNeeded: true)
        #expect(fixture.accounts.accounts.first { $0.id == account.id }?.status == .signInNeeded)
        fixture.store.status.settle(id)  // what the re-check timer runs
        #expect(fixture.accounts.accounts.first { $0.id == account.id }?.status == .signInNeeded)
        // A request that gets through proves the sign-in works again (as Drive has it).
        fixture.store.status.record(id, nil)
        #expect(fixture.accounts.accounts.first { $0.id == account.id }?.status == .ok)
        fixture.store.status.record(id, DropboxError.reconnect, signInNeeded: true)
        // Signing in again gives the account a new sign-in: it is OK again.
        let again: Result<Void, CloudConnectError> = try await awaitCallback { continuation in
            _ = fixture.accounts.signInAgain(
                account.id, openBrowser: openInFakeBrowser,
                done: { continuation.resume(returning: $0) })
        }
        #expect((try? again.get()) != nil)
        #expect(fixture.accounts.accounts.first { $0.id == account.id }?.status == .ok)
    }

    // B3: "already connected" names the account that matched, not the first one.
    @Test @MainActor func alreadyConnectedNamesTheMatchingAccount() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.server.configure(["account": "dbid:first"])
        let first = try await fixture.connect().get()
        try await fixture.server.configure(["account": "dbid:second"])
        let second = try await fixture.connect().get()
        #expect(first.id != second.id && fixture.accounts.accounts.first?.id == first.id)
        guard case .failure(.alreadyConnected(let named)) = try await fixture.connect() else {
            Issue.record("the same account was connected twice"); return
        }
        #expect(named.id == second.id)
    }

    // B4: a paused transfer stops waiting when it is interrupted (quit, sleep), as a Drive one does.
    @Test(.timeLimit(.minutes(1))) func pausedThenInterruptedTransfersStop() async throws {
        let server = try FakeDropboxServer()
        let provider = DropboxProvider(client: try server.client())
        let control = Shell.TransferControl(isPaused: { true }, isCancelled: { false }, isInterrupted: { true })
        let context = Shell.withTransferControl(control) { provider.transferContext() }
        // Still paused, for good: the checkpoint returns only because it doesn't wait out a pause once interrupted.
        var thrown: Error?
        do { try await context.checkpoint() } catch { thrown = error }
        #expect(
            {
                if case .interrupted = thrown as? FileOperationError { return true }; return false
            }())
        // The tools' own check too.
        #expect({ do { try control.check(); return false } catch FileOperationError.interrupted { return true } catch { return false } }())
    }

    // B5: Dropbox's blocking calls know a cooperative-pool thread (where they assert, as Drive's do).
    @Test func blockingCallsKnowTheCooperativePool() async throws {
        #expect(CloudAwait.onCooperativeThread)
        let onThread: Bool = try await awaitCallback { continuation in
            Thread { continuation.resume(returning: CloudAwait.onCooperativeThread) }.start()
        }
        #expect(!onThread)
        let value: Int = try await offThePool { try CloudAwait.run { 42 } }
        #expect(value == 42)
    }

    // Signing out ends the sign-in at Dropbox too, not only here.
    @Test @MainActor func signingOutRevokesTheToken() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect().get()
        let error: Error? = try await awaitCallback { continuation in
            fixture.accounts.remove(account.id) { continuation.resume(returning: $0) }
        }
        #expect(error == nil, "signing out failed: \(String(describing: error))")
        #expect(fixture.store.accounts.isEmpty)
        // The revoke goes on its own, after signing out here has finished.
        try await expectEventually { try await fixture.server.stats()["revoked"] as? Int == 1 }
        let revoke = try await fixture.server.requests().filter { $0["route"] as? String == "auth/token/revoke" }
        #expect(revoke.count == 1 && revoke.first?["auth"] as? Bool == true)
    }

    @Test @MainActor func aFailedRevokeNeverFailsSigningOut() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect().get()
        let uuid = try #require(fixture.store.accounts.first?.id)
        try await fixture.server.configure(["failRoute": "auth/token/revoke"])
        let error: Error? = try await awaitCallback { continuation in
            fixture.accounts.remove(account.id) { continuation.resume(returning: $0) }
        }
        #expect(error == nil, "signing out failed: \(String(describing: error))")
        #expect(fixture.store.accounts.isEmpty && fixture.store.client(for: uuid) == nil)
        try await expectEventually { try await fixture.server.requests().contains { $0["route"] as? String == "auth/token/revoke" } }
    }
}
