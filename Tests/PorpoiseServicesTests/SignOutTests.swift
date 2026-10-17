import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Signing out leaves nothing of the account on this Mac: no copies, records, partial downloads, upload sessions or
/// credentials. A password typed into an address never stays in it.
@Suite(.serialized, .isolatedSettings) struct SignOutTests {
    /// Every path under `roots` that names the account (folders are named by its id).
    func traces(of id: UUID, in roots: [URL]) -> [String] {
        let needle = id.uuidString.lowercased()
        return roots.flatMap { root -> [String] in
            let all = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
            return all.filter { $0.lowercased().contains(needle) }.map { root.path + "/" + $0 }
        }
    }

    @MainActor @Test func disconnectingADriveAccountLeavesNothing() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Drive/mutations.json")
        let server = try FakeDriveServer(fixture: fixture)
        let credentials = MemoryDriveCredentials()
        let suite = "porpoise-signout-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DriveAccountStore(
            defaults: defaults, credentials: credentials, configuration: server.config, baseURL: server.base.appendingPathComponent("drive/v3/"))
        let browser: @MainActor (URL) -> Void = { url in Task { _ = try? await URLSession.shared.data(from: url) } }
        let account = try await store.connect(openBrowser: browser)
        defer { RemoteFS.unregisterDrive(accountID: account.id) }
        let client = try #require(store.client(for: account.id))
        let fm = FileManager.default

        // An offline copy.
        let file = try await client.file("binary-a")
        let copy = try await client.offlineCopies().fetch(client.contentSource.remoteItem(file))
        #expect(fm.fileExists(atPath: copy.path))
        // Previews, opened files and edited copies (with a conflict copy) live in the account's folder.
        let folder = client.metadataCache.directory
        for path in ["Edits/binary-a/r1/s/report.txt", "Edits/binary-a/r1/s/Remote-report.txt", "OpenFiles/k/report.txt", "Previews/k/p.png"] {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bytes".utf8).write(to: url)
        }
        // A transfer record with its partial download and its upload session.
        var record = DriveMutationRecord(operationID: UUID(), accountID: account.id, kind: "upload", name: "big.mov")
        record.hasSession = true
        record.downloadOperationID = UUID()
        try client.mutationJournal.save(record)
        let partial = client.mutationJournal.partial(try #require(record.downloadOperationID))
        try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial)
        let sessionKey = server.config.clientID + ".upload-session"
        try credentials.save("https://www.googleapis.com/upload/drive/v3/files?upload_id=x", clientID: sessionKey, accountID: record.operationID)
        // Someone else's record stays.
        let other = DriveMutationRecord(operationID: UUID(), accountID: UUID(), kind: "upload")
        try client.mutationJournal.save(other)
        defer { try? client.mutationJournal.remove(other.operationID) }

        try await store.disconnect(account)

        #expect(!fm.fileExists(atPath: copy.path) && !fm.fileExists(atPath: folder.path) && !fm.fileExists(atPath: partial.path))
        #expect(try client.mutationJournal.all(accountID: account.id).isEmpty)
        #expect(try client.mutationJournal.load(other.operationID) != nil)
        #expect(try credentials.read(clientID: sessionKey, accountID: record.operationID) == nil)
        #expect(try credentials.read(clientID: server.config.clientID, accountID: account.id) == nil)
        let roots = [Settings.supportFolder, Settings.cachesFolder, CloudOffline.shared.root, client.mutationJournal.folder]
        #expect(traces(of: account.id, in: roots).isEmpty, "\(traces(of: account.id, in: roots))")
    }

    @Test func passwordsInAddressesGoToTheKeychain() {
        let store = MemoryCredentials()
        let typed = URL(string: "ftp://alex:s%40cret@files.example.com/pub/")!
        let kept = RemoteFS.storingPassword(typed, in: store)
        #expect(kept.absoluteString == "ftp://alex@files.example.com/pub/" && kept.password == nil)
        #expect(store.password(server: "files.example.com", account: "alex", scheme: "ftp") == "s@cret")
        // Other schemes lose the password too, without storing it; no password, no change.
        let sftp = RemoteFS.storingPassword(URL(string: "sftp://alex:pw@host/x")!, in: store)
        #expect(sftp.absoluteString == "sftp://alex@host/x" && store.password(server: "host", account: "alex", scheme: "sftp") == nil)
        #expect(RemoteFS.withoutPassword(URL(string: "ftp://alex@host/")!).absoluteString == "ftp://alex@host/")
        #expect(RemoteFS.withoutPassword(URL(fileURLWithPath: "/tmp")) == URL(fileURLWithPath: "/tmp"))
    }

    @MainActor @Test func placesNeverSaveAPassword() throws {
        let scratch = try Scratch()
        let file = scratch.path("places.json")
        let model = PlacesModel(storeURL: file)
        model.add(URL(string: "ftp://alex:hunter2@files.example.com/pub/")!, title: "Files")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.contains("files.example.com") && !saved.contains("hunter2"))
    }

    @Test func releaseBuildsIgnoreOverrides() {
        let defaults = MemoryDefaults()
        defaults.set("settings-key", forKey: "dropboxAppKey")
        let env = ["PORPOISE_DROPBOX_APP_KEY": "env-key"]
        #expect(DropboxConfiguration.selected(defaults: defaults, environment: env, testing: true).appKey == "env-key")
        // A release honours the user's own setting, never the environment.
        #expect(DropboxConfiguration.selected(defaults: defaults, environment: env, testing: false).appKey == "settings-key")
    }
}
