import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A pasted Drive folder link (gdrive://account/folder/<id>) shows where the folder really is, read from its parents:
/// in My Drive, shared with this account, or in a shared drive. Nothing is guessed while they're being read.
@MainActor @Suite(.serialized, .isolatedSettings) struct DriveAncestryTests {
    static let folder = "application/vnd.google-apps.folder"

    func fixture(_ scratch: Scratch) throws -> URL {
        let demo = try JSONSerialization.jsonObject(with: Data(contentsOf: FakeDriveServer.fixture("ui-demo.json"))) as? [String: Any] ?? [:]
        func folder(_ id: String, _ name: String, parent: String?, drive: String? = nil) -> [String: Any] {
            var f: [String: Any] = [
                "id": id, "name": name, "mimeType": Self.folder, "capabilities": ["canListChildren": true, "canAddChildren": true],
            ]
            if let parent { f["parents"] = [parent] }
            if let drive { f["driveId"] = drive }
            return f
        }
        return try FakeDriveServer.writeFixture(
            in: scratch,
            [
                "profiles": demo["profiles"] ?? [], "drives": [["id": "studio", "name": "Studio"]], "sharedWithMeIDs": ["shared-top"],
                "files": [
                    folder("root", "My Drive", parent: nil),
                    folder("nest-a", "Projects", parent: "root"), folder("nest-b", "2026", parent: "nest-a"),
                    folder("nest-c", "Launch", parent: "nest-b"),
                    // Shared by someone else: the folder above it can't be read.
                    folder("shared-top", "Client files", parent: "someone-elses"), folder("shared-in", "Drafts", parent: "shared-top"),
                    folder("studio", "Studio", parent: nil, drive: "studio"), folder("sd-a", "Assets", parent: "studio", drive: "studio"),
                    folder("sd-b", "Logos", parent: "sd-a", drive: "studio"),
                ],
            ])
    }

    /// Connects an account to a fake with the fixture above; returns the backend and the account's id.
    func connected(_ scratch: Scratch) async throws -> (FakeDriveServer, DriveCloudBackend, DriveAccountStore, UUID) {
        let server = try FakeDriveServer(fixture: try fixture(scratch))
        let (backend, store) = server.backend(scratch: scratch)
        let result = try await awaitCallback { c in _ = backend.connect(.googleDrive, openBrowser: openInFakeBrowser) { c.resume(returning: $0) } }
        guard case .success(let account) = result, let id = UUID(uuidString: account.id) else { throw DriveError.reconnect }
        return (server, backend, store, id)
    }

    /// The chain of a pasted link, once its parents are read: empty first (never guessed) unless they were read before.
    func chain(_ backend: DriveCloudBackend, _ url: URL, readBefore: Bool = false) async throws -> [String] {
        if !readBefore { #expect(backend.ancestors(of: url).isEmpty) }
        try #require(await eventually(20) { !backend.ancestors(of: url).isEmpty })
        return backend.ancestors(of: url).map { u in
            let c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            return (c?.percentEncodedPath ?? "") + (c?.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
    }

    @Test func pastedFoldersShowTheirRealPlace() async throws {
        let scratch = try Scratch()
        let (server, backend, store, id) = try await connected(scratch)
        defer { for a in store.accounts { RemoteFS.unregisterDrive(accountID: a.id) }; _ = server }
        let link = { (item: String) in DriveLocation(accountID: id, collection: .folder(item)).url }
        #expect(try await chain(backend, link("nest-c")) == ["/my-drive/", "/my-drive/nest-a/", "/my-drive/nest-a/nest-b/"])
        #expect(try await chain(backend, link("shared-in")) == ["/shared-with-me/", "/shared-with-me/shared-top/"])
        #expect(
            try await chain(backend, link("sd-b")) == [
                "/shared-drives/", "/shared-drives/studio/?driveID=studio", "/shared-drives/studio/sd-a/?driveID=studio",
            ])
        // A top folder of its own row has only the row above it; a location with its path keeps reading it.
        #expect(try await chain(backend, link("nest-a"), readBefore: true) == ["/my-drive/"])
        let navigated = DriveLocation(accountID: id, collection: .folder("nest-b"), navigationPath: ["my-drive", "nest-a", "nest-b"]).url
        #expect(backend.ancestors(of: navigated).map(\.path) == ["/my-drive", "/my-drive/nest-a"])
        // The names the breadcrumb and Properties show come from what was read.
        let previous = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = backend
        defer { CloudAccounts.shared.backend = previous }
        #expect(CloudAccounts.shared.ancestors(of: link("nest-c")).map(\.folderName) == ["My Drive", "Projects", "2026"])
        #expect(CloudAccounts.shared.ancestors(of: link("sd-b")).map(\.folderName) == ["Shared drives", "Studio", "Assets"])
    }

    @Test func theFoldersTreeRevealsAPastedFolderUnderItsRealParents() async throws {
        let scratch = try Scratch()
        let (server, backend, store, id) = try await connected(scratch)
        defer { for a in store.accounts { RemoteFS.unregisterDrive(accountID: a.id) }; _ = server }
        for (item, names) in [
            ("nest-c", ["Projects", "2026", "Launch"]), ("shared-in", ["Client files", "Drafts"]), ("sd-b", ["Studio", "Assets", "Logos"]),
        ] {
            let link = DriveLocation(accountID: id, collection: .folder(item)).url
            _ = try await chain(backend, link)
            let ancestors = backend.ancestors(of: link)
            let tree = RemoteFolderTree(url: ancestors[0])
            tree.reveal(ancestors + [link])
            try #require(await eventually(20) { tree.selected != nil }, "\(item)")
            let shown = tree.selected.flatMap { tree.path(to: $0.url) }?.dropFirst().map(\.name)
            #expect(shown == names, "\(item)")
        }
    }

    @Test func aCycleOrAnUnreadableItemGuessesNothing() {
        let account = UUID()
        func file(_ id: String, parent: String?) -> DriveFile {
            var f = DriveFile(id: id, name: id, mimeType: Self.folder)
            f.parents = parent.map { [$0] }
            return f
        }
        let files = ["root": file("root-id", parent: nil), "a": file("a", parent: "b"), "b": file("b", parent: "a")]
        #expect(DriveAncestry.resolve("a", account: account, file: { files[$0] }, unreachable: []) == .found([]))
        #expect(DriveAncestry.resolve("x", account: account, file: { files[$0] }, unreachable: []) == .missing("x"))
        let orphan = ["c": file("c", parent: "d")]
        #expect(DriveAncestry.resolve("c", account: account, file: { orphan[$0] }, unreachable: []) == .missing("root"))
    }
}
