import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Opening a remote file: it is downloaded to the cache, saves are uploaded back, and a copy whose edits haven't
/// reached the server is never replaced by a fresh download. Runs against a real sshd (see `SSHServer`).
@MainActor
@Suite(.serialized, .enabled(if: SSHServer.isAvailable, "needs /usr/sbin/sshd"), .sshServer)
final class RemoteOpenerTests {
    let server = SSHServer.current!
    let cache: Scratch
    private var opened: [URL] = []
    private var messages: [String] = []
    private var observer: NSObjectProtocol?

    init() throws {
        cache = try Scratch("cache")
        RemoteFS.cacheParentOverride = cache.url
        RemoteFS.use(server.provider(), for: server.url("/"))
        RemoteOpener.openFile = { [unowned self] in opened.append($0) }
        observer = NotificationCenter.default.addObserver(forName: StatusCenter.message, object: nil, queue: .main) { [unowned self] n in
            // Posted on the main queue.
            MainActor.assumeIsolated { messages.append(n.object as? String ?? "") }
        }
    }

    deinit {
        observer.map(NotificationCenter.default.removeObserver)
        RemoteOpener.openFile = { _ in }
        RemoteFS.use(nil, for: server.url("/"))
        if RemoteFS.cacheParentOverride == cache.url { RemoteFS.cacheParentOverride = nil }
    }

    /// The remote file `name` in a fresh folder, as the file view lists it.
    private func remoteFile(_ name: String, _ contents: String, test: String = #function) throws -> (item: FileItem, onServer: URL) {
        let dir = try server.folder(test)
        let onServer = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: onServer)
        let item = try #require(try server.provider().list(server.url(dir.path, isDirectory: true)).first { $0.name == name })
        return (item, onServer)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func opensADownloadedCopyAndUploadsEverySave() async throws {
        let (item, onServer) = try remoteFile("notes it's.txt", "v1")
        RemoteOpener.open(item)
        await expectEventually("opened") { opened.count == 1 }
        let local = try #require(opened.first)
        #expect(local.path.hasPrefix(cache.url.path + "/"))
        #expect(read(local) == "v1")

        // Saved in place.
        try Data("v2".utf8).write(to: local)
        await expectEventually("first upload") { read(onServer) == "v2" }

        // Saved the way most editors do: a new file replaces the old one. The watch follows it.
        try Data("v3".utf8).write(to: local, options: .atomic)
        await expectEventually("upload after the file was replaced") { read(onServer) == "v3" }
        try Data("v4".utf8).write(to: local, options: .atomic)
        await expectEventually("upload after a second replacement") { read(onServer) == "v4" }
        #expect(messages.contains("Uploaded changes to “notes it's.txt”."))
    }

    /// After a save that replaces the file, the new file is watched from the main queue. A second replacement made
    /// before that happens (the main queue busy) must still be uploaded. The re-watch is held back until then.
    @Test func aReplacementBeforeTheWatchMovesIsUploaded() async throws {
        let (item, onServer) = try remoteFile("busy.txt", "v1")
        RemoteOpener.open(item)
        await expectEventually("opened") { opened.count == 1 }
        let local = opened[0]
        let lock = NSLock()
        var held: [() -> Void] = []
        RemoteOpener.rewatchOnMain = { block in lock.withLock { held.append(block) } }
        defer { RemoteOpener.rewatchOnMain = { DispatchQueue.main.async(execute: $0) } }

        try Data("v2".utf8).write(to: local, options: .atomic)
        await expectEventually("first upload") { read(onServer) == "v2" }
        // Replaced again while the re-watch waits.
        try Data("v3".utf8).write(to: local, options: .atomic)
        RemoteOpener.rewatchOnMain = { DispatchQueue.main.async(execute: $0) }
        let blocks = lock.withLock { held }
        try #require(!blocks.isEmpty)  // one per event the replaced file got
        blocks.forEach { $0() }
        await expectEventually("upload of the replacement made before the watch moved") { read(onServer) == "v3" }
    }

    /// A file that can't be downloaded: an error in the status bar, nothing opened.
    @Test func aFailedDownloadIsReported() async throws {
        let curl = try RecordingTool()
        try curl.reply("", status: 9)
        let root = URL(string: "ftp://u:pw@opener-failure.invalid/")!
        RemoteFS.use(FTPProvider(url: root, curl: curl.path), for: root)
        defer { RemoteFS.use(nil, for: root) }
        RemoteOpener.open(FileItem(url: root.appendingPathComponent("dir/unreachable.txt"), name: "unreachable.txt", isDirectory: false))
        await expectEventually("error") { messages.contains { $0.hasPrefix("Could not open “unreachable.txt”") } }
        #expect(messages.contains { $0.hasPrefix("Could not open “unreachable.txt”") && $0.contains("FTP error 9") })
        #expect(opened.isEmpty)
    }

    @Test func reopeningKeepsEditsThatWereNotUploaded() async throws {
        let (item, onServer) = try remoteFile("draft.txt", "server")
        let folder = onServer.deletingLastPathComponent()
        RemoteOpener.open(item)
        await expectEventually("opened") { opened.count == 1 }
        let local = opened[0]

        // The server refuses the upload: the folder can't be written.
        #expect(chmod(folder.path, 0o555) == 0)
        defer { chmod(folder.path, 0o755) }
        try Data("my edits".utf8).write(to: local)
        await expectEventually("failed upload") { messages.contains { $0.hasPrefix("Could not upload “draft.txt”") } }
        #expect(read(onServer) == "server")

        // Opened again: the local copy with the edits, at once, without downloading over it.
        let downloadsBefore = messages.filter { $0.hasPrefix("Downloading") }.count
        RemoteOpener.open(item)
        #expect(opened.count == 2 && opened[1] == local)
        #expect(read(local) == "my edits")
        #expect(messages.filter { $0.hasPrefix("Downloading") }.count == downloadsBefore)

        // Once a save gets through, the copy is in sync and opening downloads again.
        chmod(folder.path, 0o755)
        try Data("my edits, saved again".utf8).write(to: local)
        await expectEventually("upload") { read(onServer) == "my edits, saved again" }
        await expectEventually("marked as synced") { messages.contains("Uploaded changes to “draft.txt”.") }
        try Data("changed on the server".utf8).write(to: onServer)
        RemoteOpener.open(item)
        await expectEventually("opened a third time") { opened.count == 3 }
        #expect(read(opened[2]) == "changed on the server")
    }

    @Test func reopeningASyncedCopyDownloadsItWithoutUploadingBack() async throws {
        let (item, onServer) = try remoteFile("synced.txt", "v1")
        RemoteOpener.open(item)
        await expectEventually("opened") { opened.count == 1 }
        // Opened again with nothing to upload: the earlier watch took the old copy's deletion for a save.
        try Data("v2".utf8).write(to: onServer)
        RemoteOpener.open(item)
        await expectEventually("opened again") { opened.count == 2 }
        #expect(read(opened[1]) == "v2")
        try await Task.sleep(for: .seconds(1.5))  // longer than the upload delay
        #expect(!messages.contains("Uploaded changes to “synced.txt”."))
        // Still in sync: a third open downloads the server's newer version instead of reopening the copy.
        try Data("v3".utf8).write(to: onServer)
        RemoteOpener.open(item)
        await expectEventually("opened a third time") { opened.count == 3 }
        #expect(read(opened[2]) == "v3")
    }

    @Test func cacheFolderStaysInsideTheCache() {
        let folder = RemoteOpener.cacheFolder(for: URL(string: "sftp://h.invalid/../../../etc/x/../passwd")!)
        #expect(folder.path.hasPrefix(RemoteFS.cacheRoot.path + "/"))
        #expect(!folder.pathComponents.contains(".."))
        #expect(
            RemoteOpener.cacheFolder(for: URL(string: "sftp://h.invalid/srv/a%20b/file.txt")!).path
                == cache.url.path + "/remote/sftp/h.invalid/srv/a b")
    }

    @Test func refusesNamesThatWouldLeaveTheCache() throws {
        let item = FileItem(url: server.url("/srv/.."), name: "..", isDirectory: false)
        RemoteOpener.open(item)
        #expect(opened.isEmpty && messages.isEmpty)
    }
}
