import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

private final class SyncTestRemote: SyncRemotePublishing {
    let backing: URL
    let remote: URL
    var uploads = 0
    var failUpload: Int?
    var failPublish = false
    var failListing = false
    init(backing: URL) { self.backing = backing; remote = URL(string: "sftp://\(UUID().uuidString.lowercased())/root")! }
    func local(_ url: URL) -> URL {
        backing.appendingPathComponent(String(url.path.dropFirst("/root/".count)))
    }
    func list(_ folder: URL) throws -> [FileItem] {
        if failListing { throw URLError(.networkConnectionLost) }
        let dir = folder.path == "/root" ? backing : local(folder)
        return try DirectoryLister.list(dir).map {
            FileItem(
                url: folder.appendingPathComponent($0.name), name: $0.name, isDirectory: $0.isDirectory,
                isSymlink: $0.isSymlink, size: $0.size, modificationDate: $0.modificationDate, linkDestination: $0.linkDestination)
        }
    }
    func download(_ remote: URL, into folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(remote.lastPathComponent)
        try FileManager.default.copyItem(at: local(remote), to: target); return target
    }
    func upload(_ local: URL, into folder: URL) throws {
        uploads += 1
        if uploads == failUpload { throw URLError(.networkConnectionLost) }
        try FileManager.default.copyItem(at: local, to: self.local(folder.appendingPathComponent(local.lastPathComponent)))
    }
    func publishSyncFile(_ staged: URL, to target: URL, modified: Date?) throws {
        if failPublish { throw URLError(.networkConnectionLost) }
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: local(staged).path) }
        guard Darwin.rename(local(staged).path, local(target).path) == 0 else { throw POSIXError(.EIO) }
    }
    func delete(_ remote: [URL]) throws { for url in remote { try FileManager.default.removeItem(at: local(url)) } }
    func makeFolder(_ remote: URL) throws { try FileManager.default.createDirectory(at: local(remote), withIntermediateDirectories: false) }
    func rename(_ remote: URL, to name: String) throws {
        try FileManager.default.moveItem(at: local(remote), to: local(remote.deletingLastPathComponent().appendingPathComponent(name)))
    }
    func move(_ remote: [URL], into folder: URL) throws {
        for url in remote { try FileManager.default.moveItem(at: local(url), to: local(folder.appendingPathComponent(url.lastPathComponent))) }
    }
    func copy(_ remote: [URL], into folder: URL) throws {
        for url in remote { try FileManager.default.copyItem(at: local(url), to: local(folder.appendingPathComponent(url.lastPathComponent))) }
    }
    func rootTitle(_ url: URL) -> String { "Test remote" }
}

struct SyncRemoteTests {
    @Test func lostConnectionStopsAndRerunDoesNotRepeatCompletedCopy() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), backing = try scratch.folder("remote")
        try scratch.file("left/a", "first"); try scratch.file("left/b", "second")
        let provider = SyncTestRemote(backing: backing)
        RemoteFS.use(provider, for: provider.remote); defer { RemoteFS.use(nil, for: provider.remote) }
        func plan() throws -> SyncPlan {
            SyncPlanner.plan(SyncComparator.compare(try SyncScanner.scan(left), try SyncScanner.scan(provider.remote)), mode: .backup)
        }
        provider.failUpload = 2
        var completed: [String] = []
        #expect(throws: (any Error).self) {
            try SyncExecutor.execute(plan(), leftRoot: left, rightRoot: provider.remote) { completed.append($0.path) }
        }
        #expect(completed == ["a"]); #expect(scratch.read("remote/a") == "first"); #expect(scratch.read("remote/b") == nil)
        let remaining = try plan()
        #expect(remaining.steps.map(\.path) == ["b"])
        provider.failUpload = nil
        try SyncExecutor.execute(remaining, leftRoot: left, rightRoot: provider.remote)
        #expect(provider.uploads == 3); #expect(try plan().steps.isEmpty)
        provider.failListing = true
        #expect(throws: (any Error).self) { try SyncScanner.scan(provider.remote) }
    }
    @Test func failedReplaceKeepsOriginalAndTrashIsRecoverable() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), backing = try scratch.folder("remote")
        try scratch.file("left/a", "new content"); try scratch.file("remote/a", "original")
        let provider = SyncTestRemote(backing: backing)
        RemoteFS.use(provider, for: provider.remote); defer { RemoteFS.use(nil, for: provider.remote) }
        let comparison = try SyncComparator.compare(SyncScanner.scan(left), SyncScanner.scan(provider.remote))
        provider.failPublish = true
        #expect(throws: (any Error).self) {
            try SyncExecutor.execute(SyncPlanner.plan(comparison, mode: .backup), leftRoot: left, rightRoot: provider.remote)
        }
        #expect(scratch.read("remote/a") == "original")
        provider.failPublish = false
        try SyncExecutor.execute(SyncPlanner.plan(comparison, mode: .backup), leftRoot: left, rightRoot: provider.remote)
        #expect(scratch.read("remote/a") == "new content")
        // Empty source mirror: user data moves beneath .porpoise-trash, never provider.delete.
        try FileManager.default.removeItem(at: scratch.path("left/a"))
        let mirror = SyncPlanner.plan(try SyncComparator.compare(SyncScanner.scan(left), SyncScanner.scan(provider.remote)), mode: .mirror)
        try SyncExecutor.execute(mirror, leftRoot: left, rightRoot: provider.remote)
        #expect(scratch.read("remote/a") == nil)
        let batches = try FileManager.default.contentsOfDirectory(at: scratch.path("remote/.porpoise-trash"), includingPropertiesForKeys: nil)
        #expect(batches.count == 1)
        #expect(try String(contentsOf: batches[0].appendingPathComponent("a"), encoding: .utf8) == "new content")
    }
    @Test func remoteDownloadAndContentComparison() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), backing = try scratch.folder("remote")
        try scratch.file("remote/a", "remote bytes")
        let provider = SyncTestRemote(backing: backing)
        RemoteFS.use(provider, for: provider.remote); defer { RemoteFS.use(nil, for: provider.remote) }
        let options = SyncCompareOptions(method: .content)
        let first = SyncPlanner.plan(
            try SyncComparator.compare(
                SyncScanner.scan(left, options: options), SyncScanner.scan(provider.remote, options: options), options: options), mode: .twoWay)
        try SyncExecutor.execute(first, leftRoot: left, rightRoot: provider.remote)
        #expect(scratch.read("left/a") == "remote bytes")
        let after = try SyncComparator.compare(
            SyncScanner.scan(left, options: options), SyncScanner.scan(provider.remote, options: options), options: options)
        #expect(SyncPlanner.plan(after, mode: .twoWay).steps.isEmpty)
    }
}
