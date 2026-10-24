import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct RemoteTransferPerformanceTests {
    @Test func aRepeatedNameReloadsAuthoritativeDestinationMetadata() throws {
        let s = try Scratch(), server = try Scratch()
        let provider = CountingTransferProvider(root: server.url)
        let destination = URL(string: "sftp://\(UUID().uuidString)/dst")!
        try server.folder("dst")
        RemoteFS.use(provider, for: destination)
        defer { RemoteFS.use(nil, for: destination) }
        let first = try s.file("a/file", "one"), second = try s.file("b/file", "two")
        let date = Date(timeIntervalSince1970: 1_000_000)
        provider.onUpload = {
            let stage = try #require(server.listing("dst").first { $0.hasPrefix(".porpoise-transfer-") })
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: server.path("dst/\(stage)/file").path)
        }
        let job = RemoteTransferJob(
            kind: .copy, sources: [first, second], destination: destination, control: JobControl(), rule: .ask, options: .init())
        var prompts = 0
        job.resolve = { conflict in
            prompts += 1
            #expect(conflict.destination.modificationDate == date)
            return .init(.skip)
        }
        job.run()
        #expect(prompts == 1 && job.errors.isEmpty)
        #expect(server.read("dst/file") == "one")
    }

    @Test func aBatchListsOnceAndSharesOneStageFolder() throws {
        let s = try Scratch(), server = try Scratch()
        let provider = CountingTransferProvider(root: server.url)
        let destination = URL(string: "sftp://\(UUID().uuidString)/dst")!
        try server.folder("dst")
        RemoteFS.use(provider, for: destination)
        defer { RemoteFS.use(nil, for: destination) }
        let sources = try (0..<50).map { try s.file("src/f\($0)", "\($0)") }
        let job = RemoteTransferJob(kind: .copy, sources: sources, destination: destination, control: JobControl(), rule: .ask, options: .init())
        job.run()
        #expect(job.errors.isEmpty && job.results.count == 50)
        #expect(provider.lists == 1 && provider.targetChecks == 50 && provider.folders == 1)
        #expect(server.listing("dst").count == 50)
        #expect(server.read("dst/f49") == "49")
        #expect(server.listing("dst").allSatisfy { !$0.hasPrefix(".porpoise-transfer-") })
    }

    @Test(arguments: [false, true], [false, true])
    func anArrivalOrCancellationPreservesTheMovedSource(_ cancel: Bool, _ supportsPointChecks: Bool) throws {
        let s = try Scratch(), server = try Scratch()
        let provider = CountingTransferProvider(root: server.url)
        let destination = URL(string: "sftp://\(UUID().uuidString)/dst")!
        try server.folder("dst")
        RemoteFS.use(supportsPointChecks ? provider : ListingOnlyTransferProvider(provider), for: destination)
        defer { RemoteFS.use(nil, for: destination) }
        let source = try s.file("file", "incoming"), control = JobControl()
        provider.onUpload = {
            if cancel { control.cancel() } else { try server.file("dst/file", "arrived") }
        }
        let job = RemoteTransferJob(kind: .move, sources: [source], destination: destination, control: control, rule: .ask, options: .init())
        job.run()
        #expect(job.results.isEmpty && s.read("file") == "incoming")
        #expect(server.read("dst/file") == (cancel ? nil : "arrived"))
        #expect(server.listing("dst").allSatisfy { !$0.hasPrefix(".porpoise-transfer-") })
    }
}

/// Providers such as FTP retain a fresh authoritative listing when no point lookup is available.
private final class ListingOnlyTransferProvider: RemoteProvider {
    let base: CountingTransferProvider
    init(_ base: CountingTransferProvider) { self.base = base }
    func list(_ folder: URL) throws -> [FileItem] { try base.list(folder) }
    func download(_ remote: URL, into folder: URL) throws -> URL { try base.download(remote, into: folder) }
    func upload(_ source: URL, into folder: URL) throws { try base.upload(source, into: folder) }
    func delete(_ urls: [URL]) throws { try base.delete(urls) }
    func makeFolder(_ url: URL) throws { try base.makeFolder(url) }
    func removeEmptyFolder(_ url: URL) throws { try base.removeEmptyFolder(url) }
    func rename(_ url: URL, to name: String) throws { try base.rename(url, to: name) }
    func move(_ urls: [URL], into folder: URL) throws { try base.move(urls, into: folder) }
    func copy(_ urls: [URL], into folder: URL) throws { try base.copy(urls, into: folder) }
    func rootTitle(_ url: URL) -> String { base.rootTitle(url) }
}

/// A path-based server backed by isolated local files. Counts protocol operations without network/timing noise.
final class CountingTransferProvider: RemoteProvider, RemoteTransferTargetChecking {
    let root: URL
    var lists = 0, folders = 0, targetChecks = 0
    var onUpload: () throws -> Void = {}
    var onUploadSource: (URL) throws -> Void = { _ in }
    var onDownload: () -> Void = {}
    init(root: URL) { self.root = root }
    func local(_ url: URL) -> URL { root.appendingPathComponent(url.path) }
    func list(_ folder: URL) throws -> [FileItem] {
        lists += 1
        return try FileManager.default.contentsOfDirectory(at: local(folder), includingPropertiesForKeys: nil).compactMap { url in
            guard let item = FileItem.load(url) else { return nil }
            return FileItem(
                url: folder.appendingPathComponent(item.name), name: item.name, isDirectory: item.isDirectory, size: item.size,
                modificationDate: item.modificationDate)
        }
    }
    func download(_ remote: URL, into folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(remote.lastPathComponent)
        try FileManager.default.copyItem(at: local(remote), to: target)
        onDownload()
        return target
    }
    func upload(_ source: URL, into folder: URL) throws {
        try onUploadSource(source)
        try FileManager.default.copyItem(at: source, to: local(folder).appendingPathComponent(source.lastPathComponent))
        try onUpload()
    }
    func delete(_ urls: [URL]) throws { for url in urls { try FileManager.default.removeItem(at: local(url)) } }
    func makeFolder(_ url: URL) throws { folders += 1; try FileManager.default.createDirectory(at: local(url), withIntermediateDirectories: false) }
    func removeEmptyFolder(_ url: URL) throws {
        guard rmdir(local(url).path) == 0 else { throw POSIXError(.ENOTEMPTY) }
    }
    func rename(_ url: URL, to name: String) throws {
        try FileManager.default.moveItem(at: local(url), to: local(url).deletingLastPathComponent().appendingPathComponent(name))
    }
    func move(_ urls: [URL], into folder: URL) throws {
        for url in urls { try FileManager.default.moveItem(at: local(url), to: local(folder).appendingPathComponent(url.lastPathComponent)) }
    }
    func copy(_ urls: [URL], into folder: URL) throws {
        for url in urls { try FileManager.default.copyItem(at: local(url), to: local(folder).appendingPathComponent(url.lastPathComponent)) }
    }
    func rootTitle(_ url: URL) -> String { "Test server" }
    func transferTargetExists(_ target: URL) throws -> Bool { targetChecks += 1; return FileJob.itemExists(at: local(target)) }
}
