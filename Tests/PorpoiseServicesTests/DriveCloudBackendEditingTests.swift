import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Google Drive changes as the app makes them, through DriveCloudBackend, against the fake Drive server and the UI
/// editing fixture (owned items, a folder shared as Editor, items shared as Viewer).
@MainActor @Suite(.serialized, .isolatedSettings) struct DriveCloudBackendEditingTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
        "Fixtures/Drive/ui-edit.json")
    private let browser: (URL) -> Void = { url in Task { _ = try? await URLSession.shared.data(from: url) } }

    private func connected(_ server: FakeDriveServer, scratch: Scratch) async throws -> (DriveCloudBackend, DriveAccountStore, CloudAccount) {
        let defaults = MemoryDefaults()
        let store = DriveAccountStore(
            defaults: defaults, credentials: MemoryDriveCredentials(), configuration: server.config,
            baseURL: server.base.appendingPathComponent("drive/v3/"))
        let b = DriveCloudBackend(store: store, avatarFolder: scratch.url.appendingPathComponent("avatars"))
        let result = try await awaitCallback { c in _ = b.connect(.googleDrive, openBrowser: browser) { c.resume(returning: $0) } }
        guard case .success(let account) = result else { throw CloudEditError.notSupported }
        return (b, store, account)
    }

    private func control(_ server: FakeDriveServer, _ values: [String: Any]) async throws {
        var request = URLRequest(url: server.base.appendingPathComponent("__control"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: values)
        _ = try await URLSession.shared.data(for: request)
    }

    private func call<T>(_ start: (@escaping (T) -> Void) -> Void) async throws -> T {
        try await awaitCallback { c in start { c.resume(returning: $0) } }
    }

    @Test func permissionsFollowDriveCapabilitiesAndRoles() async throws {
        let server = try FakeDriveServer(fixture: Self.fixture)
        let scratch = try Scratch()
        let (b, store, account) = try await connected(server, scratch: scratch)
        defer { for a in store.accounts { RemoteFS.unregisterDrive(accountID: a.id) } }
        await expectEventually { b.accounts.first?.canWrite == true }
        #expect(b.accounts.first?.canWrite == true)

        let myDrive = b.url(account.id, root: .myDrive)
        let drive = try #require(RemoteFS.provider(for: myDrive) as? DriveProvider)
        let mine = try await drive.refresh(myDrive)
        #expect(b.permissions(for: myDrive)?.canAddChildren == true)
        let photos = try #require(mine.first { $0.name == "Photos" })
        let owned = try #require(b.permissions(for: photos.url))
        #expect(owned.canRename && owned.canTrash && owned.canAddChildren && owned.access == .owner && owned.name == "Photos")

        let shared = b.url(account.id, root: .sharedWithMe)
        #expect(b.permissions(for: shared)?.collection == .sharedWithMe)
        #expect(b.permissions(for: b.url(account.id, root: .sharedDrives))?.collection == .sharedDrives)
        let others = try await drive.refresh(shared)
        let budget = try #require(others.first { $0.name == "Budget 2026" })
        #expect(b.permissions(for: budget.url)?.denial(.rename) == "You have view-only access to “Budget 2026”.")
        let brand = try #require(others.first { $0.name == "Brand Refresh" })
        let editor = try #require(b.permissions(for: brand.url))
        #expect(editor.canRename && !editor.canTrash && editor.access == .editor)
        #expect(editor.denial(.trash) == "Only the owner can move “Brand Refresh” to the Trash.")
        // Unknown locations: the service decides.
        #expect(b.permissions(for: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func createRenameTrashAndRestoreThroughTheService() async throws {
        let server = try FakeDriveServer(fixture: Self.fixture)
        let scratch = try Scratch()
        let (b, store, account) = try await connected(server, scratch: scratch)
        defer { for a in store.accounts { RemoteFS.unregisterDrive(accountID: a.id) } }
        let myDrive = b.url(account.id, root: .myDrive)
        let drive = try #require(RemoteFS.provider(for: myDrive) as? DriveProvider)
        _ = try await drive.refresh(myDrive)

        let created = try await call { done in b.createFolder(named: "Q4 Planning", in: myDrive) { done($0) } }.get()
        #expect(created.name == "Q4 Planning" && created.isDirectory)
        #expect(try await drive.refresh(myDrive).contains { $0.url == created.url })

        let renamed = try await call { done in b.rename(created.url, to: "Q4 Plan") { done($0) } }.get()
        #expect(renamed.name == "Q4 Plan" && renamed.url == created.url)

        let trashed = try await call { done in b.trash([created.url]) { done(($0, $1)) } }
        #expect(trashed.0 == [created.url] && trashed.1 == nil)
        #expect(try await !drive.refresh(myDrive).contains { $0.url == created.url })
        let restored = try await call { done in b.untrash([created.url]) { done(($0, $1)) } }
        #expect(restored.0 == [created.url] && restored.1 == nil)
        #expect(try await drive.refresh(myDrive).contains { $0.url == created.url })

        // A refusal comes back in the message bar's words.
        try await control(server, ["mutationFaults": [403]])
        let refused = try await call { done in b.rename(created.url, to: "X") { done($0) } }
        guard case .failure(let error) = refused else { Issue.record("expected a refusal"); return }
        #expect(error.localizedDescription == "Google Drive didn’t allow it: your access to this item may have changed.")
    }

    @Test func editErrorsSpeakPlainly() {
        func text(_ e: DriveError) -> String { DriveCloudBackend.editError(e).localizedDescription }
        #expect((DriveCloudBackend.editError(DriveError.needsWriteAccess) as? CloudEditError) == .needsWriteAccess)
        #expect(text(.notFound) == "It’s no longer in Google Drive, or no longer shared with you.")
        #expect(text(.offline) == "You’re offline. Nothing was changed.")
        #expect(text(.rateLimited) == "Google Drive is busy. Try again in a moment." && text(.quota) == text(.rateLimited))
        #expect(text(.reconnect) == "Sign in to Google Drive again to make changes.")
        #expect(text(.invalidResponse) == DriveError.invalidResponse.localizedDescription)
    }

    @Test func missingAccountsFailCalmly() async throws {
        let store = DriveAccountStore(
            defaults: MemoryDefaults(), credentials: MemoryDriveCredentials())
        let b = DriveCloudBackend(store: store, avatarFolder: FileManager.default.temporaryDirectory)
        let gone = URL(string: "gdrive://\(UUID().uuidString.lowercased())/my-drive/")!
        let created = try await call { done in b.createFolder(named: "x", in: gone) { done($0) } }
        if case .success = created { Issue.record("expected failure") }
        let trashed = try await call { done in b.trash([gone]) { done(($0, $1)) } }
        #expect(trashed.0.isEmpty && trashed.1 != nil)
        let none = try await call { done in b.trash([]) { done(($0, $1)) } }
        #expect(none.1 != nil)
        let restored = try await call { done in b.untrash([gone]) { done(($0, $1)) } }
        #expect(restored.0.isEmpty && restored.1 != nil)
        #expect(b.permissions(for: gone) == nil)
    }
}
