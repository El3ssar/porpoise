import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// One account lifecycle for every cloud service: the saved list, the state the sidebar shows, one sign-in at a time,
/// and what a failure says.
@Suite(.serialized, .isolatedSettings) struct CloudAccountLifecycleTests {
    @MainActor @Test func statusSteadiesOfflineAndKeepsSignInNeededUntilARequestGetsThrough() {
        let status = CloudAccountStatus()
        var changes = 0
        status.onChange = { changes += 1 }
        let id = UUID()
        status.record(id, nil)  // not tracked: nothing
        #expect(status[id] == nil && changes == 0)
        status.track(id)
        #expect(status[id] == .ok && changes == 1)
        status.record(id, URLError(.cancelled))  // the user stopped it: not the network
        status.record(id, DriveError.offline, skipped: true)  // never sent
        #expect(status[id] == .ok)
        status.record(id, DropboxError.reconnect, signInNeeded: true)
        #expect(status[id] == .signInNeeded)
        status.settle(id)
        status.record(id, URLError(.notConnectedToInternet))
        #expect(status[id] == .signInNeeded)  // still: a re-check or a failure can't call it OK
        status.record(id, nil)
        #expect(status[id] == .ok)
        status.forget(id)
        #expect(status[id] == nil)
    }

    @Test func savedAccountsKeepEachServicesFormat() throws {
        let defaults = MemoryDefaults()
        // As 0.8 wrote them: Drive's records name the client "clientID", Dropbox's "appKey".
        let drive = DriveAccount(subject: "sub", email: "a@example.invalid", displayName: "A")
        struct OldDrive: Codable { var account: DriveAccount; var clientID: String }
        defaults.set(try JSONEncoder().encode([OldDrive(account: drive, clientID: "client")]), forKey: "googleDriveAccounts")
        let driveRecords = CloudAccountRecords<DriveAccount>(defaults: defaults, key: "googleDriveAccounts", clientField: "clientID")
        let loaded = driveRecords.load()
        #expect(loaded.count == 1 && loaded[0].account == drive && loaded[0].clientID == "client")
        let box = DropboxAccount(
            id: UUID(), accountID: "dbid:x", email: "b@example.invalid", displayName: "B", rootNamespaceID: "r", homeNamespaceID: "h")
        let boxRecords = CloudAccountRecords<DropboxAccount>(defaults: defaults, key: "dropboxAccounts", clientField: "appKey")
        try boxRecords.save([.init(account: box, clientID: "key")])
        struct OldDropbox: Codable { var account: DropboxAccount; var appKey: String }
        let old = try JSONDecoder().decode([OldDropbox].self, from: try #require(defaults.data(forKey: "dropboxAccounts")))
        #expect(old.count == 1 && old[0].account == box && old[0].appKey == "key")
        #expect(boxRecords.load().first?.account == box)
        defaults.set(Data("not json".utf8), forKey: "dropboxAccounts")
        #expect(boxRecords.load().isEmpty)
    }

    @Test func connectFailuresSayTheSameForEveryService() {
        let account = CloudAccount(id: "a", email: "a@example.invalid", displayName: "A")
        let id = UUID()
        #expect(CloudConnectError.from(CancellationError()) { _ in nil } == .cancelled)
        #expect(CloudConnectError.from(CloudOAuthError.cancelled) { _ in nil } == .cancelled)
        #expect(CloudConnectError.from(DriveError.oauthCancelled, cancelled: { ($0 as? DriveError) == .oauthCancelled }) { _ in nil } == .cancelled)
        #expect(CloudConnectError.from(CloudConnectionError.alreadyConnected(id)) { $0 == id ? account : nil } == .alreadyConnected(account))
        // Busy reads as what it is, for Drive (it read "cancelled") and Dropbox (an unexplained failure) alike.
        #expect(CloudConnectError.from(CloudConnectionError.busy) { _ in nil } == .failed(CloudConnectionError.busy.localizedDescription))
        #expect(CloudConnectionError.busy.localizedDescription.contains("already waiting in your browser"))
        #expect(throws: CloudConnectionError.wrongAccount) { try CloudSignIn.check(expected: id, isExpected: false, existing: nil) }
        #expect(throws: CloudConnectionError.alreadyConnected(id)) { try CloudSignIn.check(expected: nil, isExpected: false, existing: id) }
        #expect(throws: Never.self) { try CloudSignIn.check(expected: id, isExpected: true, existing: id) }
    }

    @MainActor @Test func aSecondDropboxSignInWhileOneWaitsIsBusy() async throws {
        Settings.store.set("fixture-app", forKey: "dropboxAppKey")
        let server = try FakeDropboxServer()
        let store = DropboxAccountStore(
            defaults: MemoryDefaults(), credentials: MemoryCredentials(), configuration: server.config, directory: server.directory)
        var waiting: Task<DropboxAccount, Error>?
        defer { waiting?.cancel() }
        do {
            try await awaitCallback("first sign-in opened its browser") { (opened: Callback<Void>) in
                waiting = Task { @MainActor in
                    do {
                        // Opening the browser acknowledges startup; it never answers, so sign-in stays busy.
                        return try await store.connect { _ in opened.resume() }
                    } catch {
                        opened.resume(throwing: error)
                        throw error
                    }
                }
            }
        } catch {
            waiting?.cancel()
            _ = try? await waiting?.value
            throw error
        }
        let first = try #require(waiting)
        #expect(store.connecting)
        await #expect(throws: CloudConnectionError.busy) { try await store.connect { _ in } }
        first.cancel()
        _ = try? await first.value
        #expect(!store.connecting && store.accounts.isEmpty)
    }

    // Dropbox's refusals reach the message bar in words, as Drive's do (they showed "Dropbox request failed").
    @Test func dropboxChangeErrorsAreWorded() {
        for (error, words) in [
            (DropboxError.reconnect, "Sign in to Dropbox again"), (.offline, "offline"), (.notFound, "no longer in Dropbox"),
            (.conflict, "already there"), (.api(429, "too_many_requests/"), "busy"),
        ] {
            guard case .denied(let text)? = DropboxCloudBackend.editError(error) as? CloudEditError else {
                Issue.record("\(error) not worded"); continue
            }
            #expect(text.contains(words), "\(text)")
        }
        #expect(DropboxCloudBackend.editError(DropboxError.invalidResponse) as? DropboxError == .invalidResponse)
    }
}
