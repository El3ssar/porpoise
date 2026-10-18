import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Drive files edited in other apps, as the rows and Activity follow them: saves go back to the same file, a conflict
/// keeps both versions until a choice, unsent saves are kept and listed after a relaunch.
@MainActor @Suite(.serialized, .isolatedSettings) struct DriveEditingTests {
    private func setup() async throws -> (FakeDriveServer, DriveClient, DriveEditing, FileItem, Scratch) {
        let server = try DriveMutationTests().server(), scratch = try Scratch()
        let credentials = MemoryCredentials()
        let id = UUID()
        try credentials.save("fixture-refresh", clientID: server.config.clientID, accountID: id)
        let tokens = DriveTokenManager(configuration: server.config, accountID: id, credentials: credentials)
        let client = DriveClient(
            accountID: id, tokens: tokens, baseURL: server.base.appendingPathComponent("drive/v3/"),
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("Journal")), metadataDirectory: scratch.url)
        let provider = DriveProvider(accountID: id, client: client)
        RemoteFS.registerDrive(provider, accountID: id)
        let rows = try await provider.refresh(DriveLocation(accountID: id).url)
        let editing = DriveEditing()
        editing.client = { $0 == id ? client : nil }
        editing.operations = FileOperationsController()
        editing.operations.history = OperationHistory(file: scratch.url.appendingPathComponent("history"))
        editing.saveDelay = 0.05
        editing.savedShownFor = 0.2
        let item = try #require(rows.first { $0.url.lastPathComponent == "binary-a" })
        return (server, client, editing, item, scratch)
    }

    /// Every mark the row went through, as it changed: "Saved" shows for a moment only (0.2 s here), and a busy
    /// runner's polling could miss it. Each test edits one file at a time, so the row is the first entry.
    private final class Marks: NSObject {
        private(set) var seen: [CloudEditMark] = []
        private let editing: DriveEditing
        init(_ editing: DriveEditing) {
            self.editing = editing
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: DriveEditing.changed, object: nil)
        }
        @objc private func changed() {
            if let mark = editing.entries.first?.mark, seen.last != mark { seen.append(mark) }
        }
        var saves: Int { seen.filter { $0 == .saved }.count }
    }

    @Test func savesGoBackToTheSameFileAndTheRowFollows() async throws {
        let (server, client, editing, item, _) = try await setup()
        let marks = Marks(editing)
        defer {
            server.stop()
            RemoteFS.unregisterDrive(accountID: client.accountID)
        }
        var opened: [URL] = []
        var posts: [(String, Bool)] = []
        editing.openFile = { opened.append($0) }
        editing.post = { posts.append(($0, $1)) }
        #expect(editing.canEdit(item))
        var result: Bool?
        editing.open(item) { result = $0 }
        await expectEventually { result != nil }
        #expect(result == true && opened.count == 1)
        let entry = try #require(editing.entry(for: item.url))
        #expect(entry.mark == .editing && entry.title == "Editing “\(entry.name)”" && opened[0] == entry.localURL)
        #expect(entry.detail == "Changes you save in the other app go to Google Drive")

        // The other app saves: sent once the writes settle, "Saved", then back to "Editing".
        try Data("edited in another app".utf8).write(to: entry.localURL)
        await expectEventually { marks.saves == 1 }
        #expect(posts.contains { $0.0.hasPrefix("Saved “") && !$0.1 })
        let saved = try await client.file("binary-a")
        #expect(try await client.download(saved).data == Data("edited in another app".utf8))
        await expectEventually { editing.mark(for: item.url) == .editing }
        #expect(editing.entry(for: item.url)?.detail.hasPrefix("Changes save to Google Drive · last saved ") == true)

        // Opened again: the same copy, no second session.
        editing.open(item)
        #expect(opened.count == 2 && opened[1] == entry.localURL && editing.entries.count == 1)
        editing.dismiss(entry.id)
        #expect(editing.entries.isEmpty && editing.mark(for: item.url) == nil)
    }

    @Test func aConflictKeepsBothUntilTheUserChooses() async throws {
        let (server, client, editing, item, _) = try await setup()
        let marks = Marks(editing)
        defer {
            server.stop()
            RemoteFS.unregisterDrive(accountID: client.accountID)
        }
        var opened: [URL] = []
        var posts: [(String, Bool)] = []
        editing.openFile = { opened.append($0) }
        editing.post = { posts.append(($0, $1)) }
        editing.open(item)
        await expectEventually { editing.entry(for: item.url) != nil }
        let entry = try #require(editing.entry(for: item.url))
        try await server.control(["conflictOnSave": true])
        try Data("mine".utf8).write(to: entry.localURL)
        await expectEventually { editing.mark(for: item.url) == .conflict }
        let conflicted = try #require(editing.entry(for: item.url))
        #expect(conflicted.mark == .conflict && conflicted.mark.needsAttention && conflicted.conflictURL != nil)
        #expect(conflicted.title.hasSuffix("changed in Google Drive while you edited it"))
        #expect(posts.contains { $0.0.contains("Both versions are kept") && $0.1 })
        #expect(try await client.download(client.file("binary-a")).data == Data("remote edit".utf8))

        // Saving again while it waits sends nothing; Open Both shows the two; Keep Both adds mine next to it.
        editing.save(entry.id)
        #expect(editing.mark(for: item.url) == .conflict)
        editing.openBoth(entry.id)
        #expect(opened.suffix(2) == [entry.localURL, try #require(conflicted.conflictURL)])
        let saves = marks.saves
        editing.keepBoth(entry.id)
        await expectEventually { marks.saves > saves }
        #expect(editing.entries.first?.conflictURL == nil)
        #expect(try await client.download(client.file("binary-a")).data == Data("remote edit".utf8))
        #expect(posts.contains { $0.0.hasPrefix("Kept both versions of") })
        // The other app's saves now go to the new file, which carries the mark.
        let kept = try #require(editing.entries.first)
        #expect(kept.fileID != "binary-a" && kept.name.hasSuffix("(edited on Mac).txt") && editing.mark(for: item.url) == nil)
    }

    @Test func replaceWithMineAndUnsentEditsAfterARelaunch() async throws {
        let (server, client, editing, item, _) = try await setup()
        let marks = Marks(editing)
        defer {
            server.stop()
            RemoteFS.unregisterDrive(accountID: client.accountID)
        }
        editing.open(item)
        await expectEventually { editing.entry(for: item.url) != nil }
        let entry = try #require(editing.entry(for: item.url))
        try await server.control(["conflictOnSave": true])
        try Data("mine wins".utf8).write(to: entry.localURL)
        await expectEventually { editing.mark(for: item.url) == .conflict }
        editing.replaceWithMine(entry.id)
        await expectEventually { marks.saves == 1 }
        #expect(try await client.download(client.file("binary-a")).data == Data("mine wins".utf8))

        // Offline: kept, listed as unsent, sent when the connection is back.
        await expectEventually { editing.mark(for: item.url) == .editing }
        client.setOffline(true)
        try Data("written offline".utf8).write(to: entry.localURL)
        await expectEventually {
            if case .unsent = editing.mark(for: item.url) { return true }
            return false
        }
        let unsent = try #require(editing.entry(for: item.url))
        #expect(unsent.title == "1 unsent edit to “\(unsent.name)”" && unsent.detail.hasPrefix("You’re offline."))
        #expect(unsent.mark.note("Google Drive") == "Not in Google Drive yet · kept on this Mac")
        client.setOffline(false)
        editing.retryUnsent()
        await expectEventually { marks.saves == 2 }
        #expect(try await client.download(client.file("binary-a")).data == Data("written offline".utf8))

        // A save that never went (the app quit first) is listed after a relaunch and sent.
        try Data("before the quit".utf8).write(to: entry.localURL)
        let relaunched = DriveEditing()
        let relaunchedMarks = Marks(relaunched)
        relaunched.client = editing.client
        relaunched.restore(accounts: [client.accountID])
        await expectEventually { relaunched.entry(for: item.url) != nil }
        #expect(relaunched.entries.count == 1)
        await expectEventually { relaunchedMarks.saves == 1 }
        #expect(try await client.download(client.file("binary-a")).data == Data("before the quit".utf8))
    }

    @Test func marksSayWhatsGoingOn() {
        #expect(FileFormat.noted("Report.pdf", "edited on Mac") == "Report (edited on Mac).pdf")
        #expect(FileFormat.noted("backup.tar.gz", "x") == "backup (x).tar.gz" && FileFormat.noted("Notes", "x") == "Notes (x)")
        let all: [CloudEditMark] = [.editing, .saving, .saved, .unsent("x"), .conflict]
        #expect(Set(all.map(\.symbol)).count == 5)
        #expect(all.filter(\.needsAttention) == [.unsent("x"), .conflict])
        #expect(CloudEditMark.saving.note("Google Drive") == "Saving to Google Drive…")
        #expect(DriveEditing.mark(.saved) == .saved && DriveEditing.mark(.saved, fresh: true) == .editing)
        #expect(DriveEditing.mark(.unsent("Later.")) == .unsent("Later.") && DriveEditing.mark(.saving) == .saving)
        #expect(DriveEditing().mark(for: URL(string: "https://example.com")!) == nil)
    }
}
