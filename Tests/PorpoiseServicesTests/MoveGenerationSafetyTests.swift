import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct MoveGenerationSafetyTests {
    @Test(arguments: ["edit", "replace", "child", "directoryReplace", "unchanged", "corrupt"])
    func uploadBoundaryPreservesNewerLocalSource(_ change: String) throws {
        let scratch = try Scratch(), server = try Scratch()
        let provider = CountingTransferProvider(root: server.url)
        let destination = URL(string: "sftp://\(UUID().uuidString)/dst")!
        try server.folder("dst")
        RemoteFS.use(provider, for: destination)
        defer { RemoteFS.use(nil, for: destination) }
        let source = (change == "child" || change == "directoryReplace") ? try scratch.folder("source") : try scratch.file("source", "old bytes")
        if change == "child" || change == "directoryReplace" { try scratch.file("source/old", "old bytes") }
        provider.onUpload = {
            switch change {
            case "edit": try scratch.file("source", "new unsent bytes")
            case "replace":
                try FileManager.default.moveItem(at: source, to: scratch.path("previous"))
                try scratch.file("source", "replacement")
            case "child": try scratch.file("source/new", "new unsent bytes")
            case "directoryReplace":
                try FileManager.default.moveItem(at: source, to: scratch.path("previous"))
                try scratch.folder("source")
            case "corrupt":
                let stage = try #require(server.listing("dst").first { $0.hasPrefix(".porpoise-transfer-") })
                try server.file("dst/\(stage)/source", "corruption")
            default: break
            }
        }
        let job = RemoteTransferJob(kind: .move, sources: [source], destination: destination, control: JobControl(), rule: .ask, options: .init())
        job.run()
        if change == "unchanged" {
            #expect(job.errors.isEmpty && !FileJob.itemExists(at: source))
        } else {
            #expect(FileJob.itemExists(at: source))
            #expect(job.errors.contains { $0.contains("source retained") })
        }
        if change != "corrupt" {
            #expect(server.read((change == "child" || change == "directoryReplace") ? "dst/source/old" : "dst/source") == "old bytes")
        }
        if change == "child" { #expect(scratch.read("source/new") == "new unsent bytes") }
    }

    @Test func unsupportedRemoteRemovalIsNeverUnconditional() throws {
        let scratch = try Scratch(), server = try Scratch()
        let provider = CountingTransferProvider(root: server.url)
        let source = URL(string: "sftp://\(UUID().uuidString)/source")!
        try server.file("source", "old bytes")
        RemoteFS.use(provider, for: source)
        defer { RemoteFS.use(nil, for: source) }
        let job = RemoteTransferJob(kind: .move, sources: [source], destination: scratch.url, control: JobControl(), rule: .ask, options: .init())
        job.run()
        #expect(server.read("source") == "old bytes" && scratch.read("source") == "old bytes")
        #expect(job.errors.contains { $0.contains("specific source generation") })
    }
}

struct ConditionalMoveGenerationSafetyTests {
    @Test(arguments: [false, true])
    func conditionalRemovalUsesRevisionCapturedBeforeDownload(_ change: Bool) throws {
        let server = try Scratch(), destination = try Scratch()
        let source = URL(string: "sftp://\(UUID().uuidString)/source")!
        try server.file("source", "old bytes")
        let provider = RevisionedMoveProvider(root: server.url)
        if change { provider.afterDownload = { try provider.edit("new unsent bytes") } }
        RemoteFS.use(provider, for: source)
        defer { RemoteFS.use(nil, for: source) }
        let job = RemoteTransferJob(kind: .move, sources: [source], destination: destination.url, control: JobControl(), rule: .ask, options: .init())
        job.run()
        #expect(destination.read("source") == "old bytes")
        if change {
            #expect(server.read("source") == "new unsent bytes")
            #expect(job.errors.contains { $0.contains("source retained") })
            #expect(provider.removals == 0)
        } else {
            #expect(server.read("source") == nil && job.errors.isEmpty)
            #expect(provider.removals == 1)
        }
    }
}

/// All writes and conditional deletes share one lock: the fake server checks the revision and
/// removes it in one operation. No fresh lookup followed by an unguarded provider.delete.
private final class RevisionedMoveProvider: RemoteTransferConditionalRemoval {
    let base: CountingTransferProvider
    let lock = NSLock()
    var revision = 0
    var removals = 0
    var afterDownload: () throws -> Void = {}
    init(root: URL) { base = CountingTransferProvider(root: root) }
    func edit(_ text: String) throws {
        try lock.withLock {
            try Data(text.utf8).write(to: base.root.appendingPathComponent("source"))
            revision += 1
        }
    }
    func captureTransferRemoval(_ source: URL) throws -> RemoteRemovalReceipt {
        let expected = lock.withLock { revision }
        return RemoteRemovalReceipt {
            try self.lock.withLock {
                guard self.revision == expected else { throw RemoteError.failed("Copy published; source retained because its revision changed.") }
                try self.base.delete([source])
                self.removals += 1
            }
        }
    }
    func list(_ folder: URL) throws -> [FileItem] { try base.list(folder) }
    func download(_ remote: URL, into folder: URL) throws -> URL {
        let local = try base.download(remote, into: folder)
        try afterDownload()
        return local
    }
    func upload(_ source: URL, into folder: URL) throws { try base.upload(source, into: folder) }
    func delete(_ urls: [URL]) throws { Issue.record("Unconditional source delete must not be called") }
    func makeFolder(_ url: URL) throws { try base.makeFolder(url) }
    func rename(_ url: URL, to name: String) throws { try base.rename(url, to: name) }
    func move(_ urls: [URL], into folder: URL) throws { try base.move(urls, into: folder) }
    func copy(_ urls: [URL], into folder: URL) throws { try base.copy(urls, into: folder) }
    func rootTitle(_ url: URL) -> String { "Revisioned fake" }
}

@MainActor
@Suite(.serialized, .enabled(if: SSHServer.isAvailable, "needs /usr/sbin/sshd"), .sshServer, .isolatedSettings)
struct SSHMoveGenerationSafetyTests {
    @Test func changedRemoteSourceAtUploadBoundaryIsRetained() throws {
        let scratch = try Scratch(), destinationFiles = try Scratch()
        let source = try scratch.file("source", "old bytes")
        let server = SSHServer.current!, remote = server.url(source.path)
        let destination = URL(string: "sftp://\(UUID().uuidString)/dst")!
        try destinationFiles.folder("dst")
        let destinationProvider = CountingTransferProvider(root: destinationFiles.url)
        destinationProvider.onUpload = { try scratch.file("source", "new unsent bytes") }
        RemoteFS.use(server.provider(), for: remote)
        RemoteFS.use(destinationProvider, for: destination)
        defer {
            RemoteFS.use(nil, for: remote)
            RemoteFS.use(nil, for: destination)
        }
        let job = RemoteTransferJob(kind: .move, sources: [remote], destination: destination, control: JobControl(), rule: .ask, options: .init())
        job.run()
        #expect(scratch.read("source") == "new unsent bytes")
        #expect(destinationFiles.read("dst/source") == "old bytes")
        #expect(job.errors.contains { $0.contains("source retained") })
    }
}
