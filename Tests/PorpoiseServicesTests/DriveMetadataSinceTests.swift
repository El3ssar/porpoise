import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Drive's side of `aListingFetchedBeforeAChangeDoesNotUndoIt` (9fcb0dc): what a request read before a change made here
/// lands after it, and doesn't put the old metadata back.
@Suite(.serialized, .isolatedSettings) struct DriveMetadataSinceTests {
    /// Holds the first matching response the server gave until the test lets it through.
    private actor Hold {
        private var held: CheckedContinuation<Void, Never>?
        private var watchers: [CheckedContinuation<Void, Never>] = []
        private var taken = false
        private var released = false
        func wait() async {
            if released || taken { return }
            taken = true
            await withCheckedContinuation { c in
                held = c
                watchers.forEach { $0.resume() }
                watchers = []
            }
        }
        func untilHeld() async {
            if held != nil { return }
            await withCheckedContinuation { watchers.append($0) }
        }
        func release() {
            released = true
            held?.resume()
            held = nil
        }
    }

    /// A client of the fake server whose transport holds the first response matching `holds`, read before anything
    /// else happens, until released.
    private func client(holding holds: @escaping @Sendable (URLRequest) -> Bool) throws -> (FakeDriveServer, DriveClient, Hold, Scratch) {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let credentials = MemoryCredentials()
        let id = UUID()
        try credentials.save("fixture-refresh", clientID: server.config.clientID, accountID: id)
        let tokens = DriveTokenManager(configuration: server.config, accountID: id, credentials: credentials)
        let hold = Hold()
        let forward = DriveHTTP()
        let http = DriveHTTP { request in
            let reply = try await forward.response(request)
            if holds(request) { await hold.wait() }
            return reply
        }
        let client = DriveClient(
            accountID: id, tokens: tokens, http: http, baseURL: server.base.appendingPathComponent("drive/v3/"),
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("Journal")), metadataDirectory: scratch.url)
        return (server, client, hold, scratch)
    }

    @Test func aListingAskedForBeforeARenameDoesNotPutTheOldNameBack() async throws {
        let (server, client, hold, _) = try client { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/drive/v3/files") == true }
        defer { server.stop() }
        let root = DriveLocation(accountID: client.accountID)
        let original = try await client.file("binary-a").name
        let listing = Task { try await client.listPage(root) }
        await hold.untilHeld()  // the server listed the old name
        let renamed = try await client.rename("binary-a", to: "renamed while listing")
        await hold.release()
        let page = try await listing.value

        #expect(original != renamed.name)
        #expect(page.files.first { $0.id == "binary-a" }?.name == "renamed while listing")
        #expect(client.metadataCache.file("binary-a")?.name == "renamed while listing")
        let url = DriveLocation(accountID: client.accountID, collection: .folder("binary-a")).url
        #expect(client.cachedFile(for: url)?.name == "renamed while listing")
        // Listed after the change: it's the newer one.
        let later = try await client.listPage(root)
        #expect(later.files.first { $0.id == "binary-a" }?.name == "renamed while listing")
    }

    @Test func aFolderListingSnapshotKeepsTheRename() async throws {
        let (server, client, hold, _) = try client { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/drive/v3/files") == true }
        defer { server.stop() }
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID)
        let listing = Task { try await provider.refresh(root.url) }
        await hold.untilHeld()
        _ = try await client.rename("binary-a", to: "renamed while listing")
        await hold.release()
        _ = try? await listing.value  // the rename may cancel this listing; what it read must not land either way
        #expect(client.metadataCache.file("binary-a")?.name == "renamed while listing")
        let snapshot = client.metadataCache.snapshot(root)?.files.first { $0.id == "binary-a" }
        #expect(snapshot == nil || snapshot?.name == "renamed while listing")
    }

    @Test func aLookupAskedForBeforeARenameDoesNotPutTheOldNameBack() async throws {
        let (server, client, hold, _) = try client { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/drive/v3/files/binary-a") == true }
        defer { server.stop() }
        _ = try await client.listPage(DriveLocation(accountID: client.accountID))
        let lookup = Task { try await client.file("binary-a") }
        await hold.untilHeld()
        // The rename looks the file up too (not held: only the first response is), then changes it.
        _ = try await client.rename("binary-a", to: "renamed while looking")
        await hold.release()
        #expect(try await lookup.value.name == "renamed while looking")
        #expect(client.metadataCache.file("binary-a")?.name == "renamed while looking")
    }

    /// Edit sessions name the file and where its edited copy is: only this user reads them, as with Dropbox's.
    @Test func editSessionsAreReadableOnlyByTheUser() async throws {
        let (server, client, hold, scratch) = try client { _ in false }
        defer { server.stop() }
        await hold.release()
        let store = DriveEditStore(client: client, directory: scratch.url.appendingPathComponent("Edits"))
        let file = try await client.file("binary-a")
        let session = try await store.open(file)
        let json = scratch.url.appendingPathComponent("Edits").appendingPathComponent(session.id.uuidString + ".json")
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: json.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
    }
}
