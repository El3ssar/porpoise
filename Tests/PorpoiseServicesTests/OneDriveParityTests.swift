import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// OneDrive accounts and transfers behave as Drive's and Dropbox's do: sign-in state, the account a refusal names,
/// pausing, blocking calls and signing out.
@Suite(.serialized, .isolatedSettings) struct OneDriveParityTests {
    @MainActor final class Fixture {
        let server: FakeGraphServer
        let suite = "porpoise-onedrive-parity-" + UUID().uuidString
        let store: OneDriveAccountStore
        let backend: OneDriveCloudBackend
        let accounts = CloudAccounts()
        init() throws {
            Settings.store.set("fixture-client", forKey: "oneDriveClientID")
            server = try FakeGraphServer()
            store = OneDriveAccountStore(
                defaults: UserDefaults(suiteName: suite)!, credentials: MemoryCredentials(), configuration: server.config,
                directory: server.directory)
            backend = OneDriveCloudBackend(store: store)
            accounts.backend = CompositeCloudBackend([.oneDrive: backend])
        }
        func connect() async throws -> Result<CloudAccount, CloudConnectError> {
            try await awaitCallback { continuation in
                _ = accounts.connect(.oneDrive, openBrowser: openInFakeBrowser, done: { continuation.resume(returning: $0) })
            }
        }
        func cleanup() {
            backend.setActive(false)
            for account in store.accounts { RemoteFS.registerCloud(nil, for: OneDriveLocation(accountID: account.id).url) }
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    // Once OneDrive says to sign in again, a re-check scheduled before can't call the account OK.
    @Test @MainActor func signInNeededStaysUntilSignedInAgain() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect().get()
        let id = try #require(fixture.store.accounts.first?.id)
        fixture.store.status.record(id, URLError(.notConnectedToInternet))
        fixture.store.status.record(id, OneDriveError.reconnect, signInNeeded: true)
        #expect(fixture.accounts.accounts.first { $0.id == account.id }?.status == .signInNeeded)
        fixture.store.status.settle(id)
        #expect(fixture.accounts.accounts.first { $0.id == account.id }?.status == .signInNeeded)
        fixture.store.status.record(id, nil)
        #expect(fixture.accounts.accounts.first { $0.id == account.id }?.status == .ok)
        fixture.store.status.record(id, OneDriveError.reconnect, signInNeeded: true)
        let again: Result<Void, CloudConnectError> = try await awaitCallback { continuation in
            _ = fixture.accounts.signInAgain(account.id, openBrowser: openInFakeBrowser, done: { continuation.resume(returning: $0) })
        }
        #expect((try? again.get()) != nil)
        #expect(fixture.accounts.accounts.first { $0.id == account.id }?.status == .ok)
        // A refused refresh is "sign in again", reported by the client to the account's status.
        try await fixture.server.configure(["denyToken": true])
        let client = try #require(fixture.store.client(for: id))
        _ = try await client.tokens.disconnect()
        await #expect(throws: OneDriveError.reconnect) { try await client.metadata("FIXTURE!hello") }
        let deadline = Date().addingTimeInterval(5)
        while fixture.accounts.accounts.first?.status != .signInNeeded, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(fixture.accounts.accounts.first?.status == .signInNeeded)
    }

    // "Already connected" names the account that matched, not the first one.
    @Test @MainActor func alreadyConnectedNamesTheMatchingAccount() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.server.configure(["account": "first-user"])
        let first = try await fixture.connect().get()
        try await fixture.server.configure(["account": "second-user"])
        let second = try await fixture.connect().get()
        #expect(first.id != second.id && fixture.accounts.accounts.first?.id == first.id)
        guard case .failure(.alreadyConnected(let named)) = try await fixture.connect() else {
            Issue.record("the same account was connected twice"); return
        }
        #expect(named.id == second.id)
    }

    // A paused transfer stops waiting when it is interrupted (quit, sleep), as a Drive one does.
    @Test func pausedThenInterruptedTransfersStop() async throws {
        let server = try FakeGraphServer()
        let provider = OneDriveProvider(client: try server.client())
        let control = Shell.TransferControl(isPaused: { true }, isCancelled: { false }, isInterrupted: { true })
        let context = Shell.withTransferControl(control) { provider.transferContext() }
        let started = Date()
        var thrown: Error?
        do { try await context.checkpoint() } catch { thrown = error }
        #expect(
            {
                if case .interrupted = thrown as? FileOperationError { return true }; return false
            }())
        #expect(Date().timeIntervalSince(started) < 2)
    }

    // The account shows its quota, from the drive, as Drive's and Dropbox's do.
    @Test @MainActor func quotaComesFromTheDrive() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.server.configure(["quota": ["used": 123, "total": 456]])
        let account = try await fixture.connect().get()
        let deadline = Date().addingTimeInterval(5)
        while fixture.accounts.accounts.first?.quotaTotal == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let shown = try #require(fixture.accounts.accounts.first { $0.id == account.id })
        #expect(shown.quotaUsed == 123 && shown.quotaTotal == 456 && shown.provider == .oneDrive)
    }

    // Signing out forgets the sign-in here; Microsoft has no single-token revoke, so nothing else is sent.
    @Test @MainActor func signingOutForgetsTheSignInAndSendsNoRevoke() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect().get()
        let uuid = try #require(fixture.store.accounts.first?.id)
        let before = try await fixture.server.requests().count
        let error: Error? = try await awaitCallback { continuation in
            fixture.accounts.remove(account.id) { continuation.resume(returning: $0) }
        }
        #expect(error == nil, "signing out failed: \(String(describing: error))")
        #expect(fixture.store.accounts.isEmpty && fixture.store.client(for: uuid) == nil)
        let after = try await fixture.server.requests().dropFirst(before)
        #expect(!after.contains { ($0["route"] as? String)?.contains("revoke") == true })
        #expect(RemoteFS.provider(for: OneDriveLocation(accountID: uuid).url) as? OneDriveProvider == nil)
    }

    // Edit failures reach the message bar in words, as Drive's and Dropbox's do.
    @Test func editErrorsAreWords() {
        for (error, words) in [
            (OneDriveError.reconnect, "Sign in to OneDrive again"), (.offline, "offline"), (.notFound, "no longer in OneDrive"),
            (.conflict, "already there"), (.api(429, "activityLimitReached"), "busy"), (.api(403, "accessDenied"), "permission"),
        ] {
            guard case .denied(let text)? = OneDriveCloudBackend.editError(error) as? CloudEditError else {
                Issue.record("\(error) has no words"); continue
            }
            #expect(text.contains(words))
        }
        #expect(OneDriveCloudBackend.editError(OneDriveError.invalidResponse) as? OneDriveError == .invalidResponse)
    }
}
