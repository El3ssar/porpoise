import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Generic SSH has no atomic revision-conditional save-back. Opens are durable local copies, never silent overwrites.
@MainActor
@Suite(.serialized, .enabled(if: SSHServer.isAvailable, "needs /usr/sbin/sshd"), .sshServer, .isolatedSettings)
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

    @Test func opensADurableCopyWithoutUnsafeAutomaticUpload() async throws {
        let (item, onServer) = try remoteFile("notes it's.txt", "server")
        RemoteOpener.open(item)
        await expectEventually("opened") { opened.count == 1 }
        let local = try #require(opened.first)
        #expect(local.path.hasPrefix(cache.url.path + "/Remote Copies/"))
        #expect(read(local) == "server")
        #expect((try FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber)?.intValue == 0o444)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
        try Data("my edits".utf8).write(to: local, options: .atomic)
        RemoteOpener.open(item)
        await expectEventually("reopened") { opened.count == 2 }
        #expect(opened[1] != local && read(local) == "my edits")
        #expect(read(opened[1]) == "server")
        #expect(read(onServer) == "server")
        #expect(messages.contains { $0.contains("Changes are not saved to the server") })
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

    @Test func reopeningNeverReplacesAnEditorsLocalCopy() async throws {
        let (item, onServer) = try remoteFile("draft.txt", "v1")
        RemoteOpener.open(item)
        await expectEventually("opened") { opened.count == 1 }
        let local = opened[0]
        try Data("changed on server".utf8).write(to: onServer)
        RemoteOpener.open(item)
        await expectEventually("opened again") { opened.count == 2 }
        #expect(opened[1] != local && read(local) == "v1")
        #expect(read(opened[1]) == "changed on server")
        #expect(read(onServer) == "changed on server")
    }

    @Test func concurrentRequestsShareThePreparedCopy() async throws {
        let (item, _) = try remoteFile("coalesced.txt", "v1")
        RemoteOpener.open(item)
        RemoteOpener.open(item)
        await expectEventually("both requests") { opened.count == 2 }
        #expect(opened[0] == opened[1])
    }

    @Test func cacheFolderStaysInsideTheCache() {
        let folder = RemoteOpener.cacheFolder(for: URL(string: "sftp://h.invalid/../../../etc/x/../passwd")!)
        #expect(folder.path.hasPrefix(RemoteFS.cacheRoot.path + "/"))
        #expect(!folder.pathComponents.contains(".."))
        #expect(
            RemoteOpener.cacheFolder(for: URL(string: "sftp://h.invalid/srv/a%20b/file.txt")!).path
                .hasPrefix(cache.url.path + "/remote/"))
    }

    @Test func refusesNamesThatWouldLeaveTheCache() throws {
        let item = FileItem(url: server.url("/srv/.."), name: "..", isDirectory: false)
        RemoteOpener.open(item)
        #expect(opened.isEmpty && messages.isEmpty)
    }
}
