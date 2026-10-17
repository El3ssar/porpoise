import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Google Drive behind the app's cloud accounts, against the local fake Drive server and the UI fixture.
@MainActor @Suite(.serialized, .isolatedSettings) struct DriveCloudBackendTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Drive/ui-demo.json")
    private let browser: (URL) -> Void = { url in Task { _ = try? await URLSession.shared.data(from: url) } }

    private func backend(_ server: FakeDriveServer, scratch: Scratch) -> (DriveCloudBackend, DriveAccountStore) {
        let defaults = MemoryDefaults()
        let store = DriveAccountStore(
            defaults: defaults, credentials: MemoryDriveCredentials(), configuration: server.config,
            baseURL: server.base.appendingPathComponent("drive/v3/"))
        return (DriveCloudBackend(store: store, avatarFolder: scratch.url.appendingPathComponent("avatars")), store)
    }

    private func connect(_ b: DriveCloudBackend) async throws -> Result<CloudAccount, CloudConnectError> {
        try await awaitCallback { c in _ = b.connect(.googleDrive, openBrowser: browser) { c.resume(returning: $0) } }
    }

    @Test func connectsTwoAccountsWithQuotaSharedDrivesAndSharing() async throws {
        let server = try FakeDriveServer(fixture: Self.fixture)
        let scratch = try Scratch()
        let (b, store) = backend(server, scratch: scratch)
        var changes = 0
        b.onChange = { changes += 1 }
        guard case .success(let one) = try await connect(b), case .success(let two) = try await connect(b) else {
            Issue.record("sign-in failed"); return
        }
        defer { for a in store.accounts { RemoteFS.unregisterDrive(accountID: a.id) } }
        #expect(one.email == "daniel@example.com" && two.email == "daniel@studio.example")
        // The same account again is shown, not added (the fixture's profiles rotate back to the first one).
        guard case .failure(.alreadyConnected(let again)) = try await connect(b) else { Issue.record("expected already connected"); return }
        #expect(again.id == one.id)
        await expectEventually { b.accounts.allSatisfy { $0.quotaTotal != nil && $0.sharedDriveCount == 2 } }
        let a = try #require(b.accounts.first { $0.id == one.id })
        #expect(a.quotaUsed == 1024 && a.quotaTotal == 16_106_127_360 && a.sharedDriveCount == 2 && a.status == .ok)
        #expect(changes > 0)

        // Locations and the account they belong to.
        let shared = b.url(one.id, root: .sharedWithMe)
        #expect(b.accountID(for: shared) == one.id && b.accountID(for: URL(fileURLWithPath: "/tmp")) == nil)
        #expect(
            b.url(one.id, root: .myDrive).absoluteString.hasSuffix("/my-drive/")
                && b.url(one.id, root: .sharedDrives).absoluteString.hasSuffix("/shared-drives/"))

        // Sharing details of listed items.
        let items = try #require(RemoteFS.provider(for: shared)).list(shared)
        let budget = try #require(items.first { $0.name == "Budget 2026" })
        let info = try #require(b.info(for: budget.url))
        #expect(info.ownerName == "Marco Bianchi" && info.access == .editor && info.isWebDocument && info.kind == "Google Sheets spreadsheet")
        #expect(info.sharingSummary == "4 people and anyone with the link (can view)" && info.sharedBy == "Marco Bianchi")
        #expect(budget.sharedDate != nil && budget.isWebDocument)
        let brand = try #require(items.first { $0.name == "Brand Refresh" })
        let folder = try #require(b.info(for: brand.url))
        #expect(folder.isFolder && folder.access == .viewer && folder.webLink?.absoluteString == "https://drive.google.com/drive/folders/fold-brand")
        #expect(b.info(for: shared) == nil)

        // Pasted links: the first account that can see the item.
        var link: CloudLinkResult?
        b.resolveLink("https://drive.google.com/drive/folders/fold-brand") { link = $0 }
        await expectEventually { link != nil }
        #expect(link == .folder(DriveLocation(accountID: try #require(UUID(uuidString: one.id)), collection: .folder("fold-brand")).url))
        link = nil
        b.resolveLink("https://docs.google.com/spreadsheets/d/sheet-budget/edit") { link = $0 }
        await expectEventually { link != nil }
        #expect(link == .file(URL(string: "https://docs.google.com/spreadsheets/d/sheet-budget/edit")!))
        link = nil
        b.resolveLink("https://drive.google.com/drive/folders/missing") { link = $0 }
        await expectEventually { link != nil }
        #expect(link == .noAccess)
        b.resolveLink("https://example.com/x") { link = $0 }
        #expect(link == .notALink)

        // Signing in again keeps the account; removing forgets it.
        let again2: Result<Void, CloudConnectError> = try await awaitCallback { c in
            _ = b.signInAgain(two.id, openBrowser: browser) { c.resume(returning: $0) }
        }
        if case .failure(let e) = again2 { Issue.record("sign in again failed: \(e)") }
        let unknown: Result<Void, CloudConnectError> = try await awaitCallback { c in
            _ = b.signInAgain("not-an-account", openBrowser: browser) { c.resume(returning: $0) }
        }
        guard case .failure(.failed) = unknown else { Issue.record("expected a failure"); return }
        let removed: Error? = try await awaitCallback { c in b.remove(two.id) { c.resume(returning: $0) } }
        #expect(removed == nil && b.accounts.map(\.id) == [one.id])
    }

    @Test func picturesAreCachedAndAccountsWithoutOneGetNone() async throws {
        let server = try FakeDriveServer(fixture: Self.fixture)
        let scratch = try Scratch()
        let (b, store) = backend(server, scratch: scratch)
        guard case .success(let one) = try await connect(b) else { Issue.record("sign-in failed"); return }
        defer { for a in store.accounts { RemoteFS.unregisterDrive(accountID: a.id) } }
        let none: Data? = try await awaitCallback { c in b.avatar(one.id) { c.resume(returning: $0) } }
        #expect(none == nil)
        // A picture fetched earlier is used from the cache folder.
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent("avatars"), withIntermediateDirectories: true)
        try Data([7, 7]).write(to: scratch.url.appendingPathComponent("avatars/\(one.id).img"))
        let cached: Data? = try await awaitCallback { c in b.avatar(one.id) { c.resume(returning: $0) } }
        #expect(cached == Data([7, 7]))
        let missing: Data? = try await awaitCallback { c in b.avatar("nobody") { c.resume(returning: $0) } }
        #expect(missing == nil)
    }

    @Test func cancellingTheSignInLeavesNothing() async throws {
        let server = try FakeDriveServer(fixture: Self.fixture)
        let scratch = try Scratch()
        let (b, store) = backend(server, scratch: scratch)
        let result: Result<CloudAccount, CloudConnectError> = try await awaitCallback { c in
            let cancel = b.connect(.googleDrive, openBrowser: { _ in }) { c.resume(returning: $0) }
            cancel()
        }
        #expect(result == .failure(.cancelled))
        #expect(store.accounts.isEmpty && b.accounts.isEmpty)
    }

    @Test func rolesKindsAndSummaries() throws {
        #expect(DriveCloudBackend.access("owner") == .owner && DriveCloudBackend.access("organizer") == .editor)
        #expect(DriveCloudBackend.access("fileOrganizer") == .editor && DriveCloudBackend.access("writer") == .editor)
        #expect(DriveCloudBackend.access("commenter") == .commenter && DriveCloudBackend.access("reader") == .viewer)
        #expect(DriveCloudBackend.access(nil) == nil && DriveCloudBackend.access("x") == nil)
        let kinds = ["document", "spreadsheet", "presentation", "form", "drawing", "site", "jam", "map"]
        #expect(kinds.compactMap { DriveCloudBackend.kind("application/vnd.google-apps." + $0) }.count == kinds.count)
        #expect(DriveCloudBackend.kind("application/pdf") == nil)
        func file(_ json: String) throws -> DriveFile { try JSONDecoder().decode(DriveFile.self, from: Data(json.utf8)) }
        let mine = try file(
            #"{"id":"f","name":"Mine","mimeType":"application/pdf","owners":[{"displayName":"Me","emailAddress":"me@x.com"}],"permissions":[{"type":"anyone","role":"commenter"}]}"#
        )
        let info = DriveCloudBackend.info(mine, me: "me@x.com")
        #expect(info.access == .owner && info.anyoneWithLink == "can comment" && info.sharedWithCount == 0 && !info.isFolder)
        let linkOnly = try file(
            #"{"id":"g","name":"Public","mimeType":"application/vnd.google-apps.folder","permissions":[{"type":"anyone","role":"writer"}]}"#)
        let shared = DriveCloudBackend.info(linkOnly, me: "someone@else.com")
        #expect(shared.access == .editor && shared.anyoneWithLink == "can edit" && shared.isFolder)
        #expect(DriveCloudBackend.info(DriveFile(id: "h", name: "Plain", mimeType: "text/plain"), me: nil).sharedWithCount == nil)
    }
}
