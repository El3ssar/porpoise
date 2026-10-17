import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct DriveOfflineLifecycleTests {
    @Test func unsentBlocksSignoutThenCleanSignoutWipesOfflineAccount() async throws {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let defaults = MemoryDefaults()
        let accounts = DriveAccountStore(
            defaults: defaults, credentials: MemoryDriveCredentials(), configuration: server.config,
            baseURL: server.base.appendingPathComponent("drive/v3/"))
        let account = try await accounts.connect { url in Task { _ = try? await URLSession.shared.data(from: url) } }
        let client = try #require(accounts.client(for: account.id))
        let backend = DriveCloudBackend(store: accounts, avatarFolder: scratch.url.appendingPathComponent("avatars"))
        let previous = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = backend
        CloudOffline.shared.activate()
        defer { CloudAccounts.shared.backend = previous }
        let key = account.id.uuidString.lowercased()
        #expect(backend.content(for: "invalid") == nil)
        #expect(backend.content(for: key)?.accountID == key)
        let file = try await client.file("binary-a")
        let store = try await client.offlineCopies()
        let source = client.contentSource
        #expect(source.ref(for: backend.url(key, root: .sharedWithMe)) == nil)
        #expect(source.ref(for: backend.url(key, root: .sharedDrives)) == nil)
        #expect(source.ref(for: backend.url(key, root: .myDrive))?.item == "root")
        let item = source.remoteItem(file)
        let copy = try await store.fetch(item, keep: true)
        let session = try await client.edits.open(file)
        try Data("unsent".utf8).write(to: session.localURL)
        await #expect(throws: CloudConnectionError.unsentEdits) { try await accounts.disconnect(account) }
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(await store.snapshot().pins.contains(file.id))
        try Data(contentsOf: copy).write(to: session.localURL)
        try await accounts.disconnect(account)
        #expect(accounts.accounts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(CloudOffline.shared.usage(account: key).kept == 0)
    }
}
