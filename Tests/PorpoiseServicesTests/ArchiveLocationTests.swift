import Foundation
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseServices

@Suite struct ArchiveLocationTests {
    private func archive(_ scratch: Scratch, format: String = "zip") throws -> URL {
        try scratch.file("src/top.txt", "top")
        try scratch.file("src/sub/inside #?% é.txt", "inside")
        try scratch.file("src/other/untouched.txt", "untouched")
        let url = scratch.path("files." + (format == "7zip" ? "7z" : format))
        if format == "zip" {
            try run("/usr/bin/zip", ["-qr", url.path, "src"], in: scratch.url)
        } else {
            try run("/usr/bin/tar", ["--format=" + format, "-cf", url.path, "-C", scratch.url.path, "src"])
        }
        return url
    }

    @Test(arguments: ["zip", "7zip", "pax"]) func listsWithoutExtractionAndCopiesOneEntry(_ format: String) throws {
        let s = try Scratch()
        let file = try archive(s, format: format)
        let root = ArchiveLocation(archive: file).url
        let provider = try #require(RemoteFS.provider(for: root))
        let before = try FileManager.default.subpathsOfDirectory(atPath: s.url.path)
        let top = try provider.list(root)
        #expect(top.map(\.name) == ["src"])
        let inside = try provider.list(root.appendingPathComponent("src/sub"))
        let item = try #require(inside.first)
        #expect(item.name == "inside #?% é.txt")
        #expect(ArchiveLocation(url: item.url)?.path == "src/sub/inside #?% é.txt")
        #expect(!item.isWritable)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: s.url.path) == before)
        let extracted = try provider.download(item.url, into: s.path("out"))
        #expect(try String(contentsOf: extracted, encoding: .utf8) == "inside")
        #expect(s.listing("out") == [item.name])
        #expect(!FileManager.default.fileExists(atPath: s.path("out/top.txt").path))
        #expect(throws: (any Error).self) { try provider.download(item.url, into: s.path("out")) }
        #expect(try String(contentsOf: extracted, encoding: .utf8) == "inside")
        let copiedFolder = try provider.download(root.appendingPathComponent("src/sub"), into: s.path("folder"))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: copiedFolder.path) == [item.name])
    }

    @Test func readOnlyProviderAndClassification() throws {
        let s = try Scratch()
        let archive = try archive(s)
        let item = try #require(FileItem.load(archive))
        let root = try #require(ArchiveBrowser.location(for: item))
        #expect(LocationKind.of(root) == .archive)
        #expect(!LocationKind.of(root).acceptsDrops)
        #expect(!LocationOperations(for: root).canAddItems(root))
        #expect(root.folderName == archive.lastPathComponent)
        let provider = try #require(RemoteFS.provider(for: root))
        let original = try Data(contentsOf: archive)
        #expect(throws: (any Error).self) { try provider.upload(s.path("src/top.txt"), into: root) }
        #expect(throws: (any Error).self) { try provider.delete([root.appendingPathComponent("src/top.txt")]) }
        #expect(throws: (any Error).self) { try provider.makeFolder(root.appendingPathComponent("new")) }
        #expect(throws: (any Error).self) { try provider.rename(root, to: "new") }
        #expect(throws: (any Error).self) { try provider.move([root], into: root) }
        #expect(throws: (any Error).self) { try provider.copy([root], into: root) }
        #expect(try Data(contentsOf: archive) == original)
        #expect(ArchiveLocation(url: URL(string: "archive://wrong/?file=/tmp/a.zip")!) == nil)
        #expect(ArchiveLocation(url: URL(string: "archive://wrong/")!) == nil)
        #expect(ArchiveBrowser.location(for: FileItem(url: URL(string: "sftp://host/a.zip")!, name: "a.zip", isDirectory: false)) == nil)
        #expect(ArchiveBrowser.location(for: FileItem(url: s.path("a.rar"), name: "a.rar", isDirectory: false)) == nil)
    }

    @Test func hostileZipHeadersAreRejectedBeforeWriting() throws {
        let s = try Scratch()
        let script = #"""
            import zipfile, tarfile, sys, stat
            root = sys.argv[1]
            for kind, name in [('dotdot','../escape'),('absolute','/tmp/escape'),('backslash','..\\escape'),('drive','C:/escape'),('deep','/'.join(['a']*70)),('special','pipe'),('symlink','link')]:
                with zipfile.ZipFile(root+'/'+kind+'.zip','w') as z:
                    info=zipfile.ZipInfo(name)
                    info.create_system=3
                    info.external_attr=((stat.S_IFLNK|0o777) if kind=='symlink' else (stat.S_IFIFO|0o600) if kind=='special' else (stat.S_IFREG|0o644))<<16
                    z.writestr(info,'/tmp' if kind=='symlink' else 'bad')
            with tarfile.open(root+'/special.tar','w') as t:
                info=tarfile.TarInfo('pipe'); info.type=tarfile.FIFOTYPE; t.addfile(info)
            with zipfile.ZipFile(root+'/bomb.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
                z.writestr('bomb',b'0'*(32*1024*1024))
            with zipfile.ZipFile(root+'/duplicate.zip','w') as z:
                z.writestr('same','one'); z.writestr('same','two')
            with zipfile.ZipFile(root+'/collision.zip','w') as z:
                z.writestr('folder','file'); z.writestr('folder/child','child')
            """#
        try run("/usr/bin/python3", ["-c", script, s.url.path])
        for name in ["dotdot", "absolute", "backslash", "drive", "deep", "symlink", "bomb", "duplicate", "collision"] {
            #expect(throws: (any Error).self) { try ArchiveIndex(s.path(name + ".zip")) }
        }
        #expect(throws: (any Error).self) { try ArchiveIndex(s.path("special.tar")) }
        // ZIP has no portable FIFO entry; macOS libarchive normalizes that mode to an ordinary file.
        // Such a ZIP can only create a regular file, never a pipe or device.
        let normalized = try ArchiveIndex(s.path("special.zip"))
        let regular = try normalized.extract("pipe", into: s.path("normalized"), name: "pipe")
        #expect(try regular.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        #expect(!FileManager.default.fileExists(atPath: s.path("out").path))
    }

    @Test func boundedEntriesSizesCancellationAndArchiveReplacement() throws {
        let s = try Scratch()
        let file = try archive(s)
        #expect(throws: (any Error).self) { try ArchiveIndex(file, limits: .init(entries: 2)) }
        #expect(throws: (any Error).self) { try ArchiveIndex(file, limits: .init(entryBytes: 2)) }
        #expect(throws: (any Error).self) { try ArchiveIndex(file, limits: .init(totalBytes: 2)) }
        #expect(throws: CancellationError.self) { try ArchiveIndex(file) { throw CancellationError() } }
        let index = try ArchiveIndex(file)
        #expect(throws: CancellationError.self) {
            try index.extract("src/top.txt", into: s.path("cancel"), name: "top.txt") { throw CancellationError() }
        }
        #expect(!FileManager.default.fileExists(atPath: s.path("cancel").path))
        let root = ArchiveLocation(archive: file).url
        let provider = try #require(RemoteFS.provider(for: root))
        _ = try provider.list(root)
        try "new contents".write(to: s.path("src/top.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/zip", ["-q", file.path, "src/top.txt"], in: s.url)
        #expect(throws: (any Error).self) { try index.extract("src/top.txt", into: s.path("old"), name: "top.txt") }
        let fresh = try provider.download(root.appendingPathComponent("src/top.txt"), into: s.path("fresh"))
        #expect(try String(contentsOf: fresh, encoding: .utf8) == "new contents")
    }

    @Test func cancellingDuringExtractionRemovesPartialAndLeavesDestinationIntact() throws {
        let s = try Scratch()
        let file = try archive(s)
        let index = try ArchiveIndex(file)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try index.extract(nil, into: s.path("out"), name: "whole") {
                checks += 1
                if checks == 6 { throw CancellationError() }
            }
        }
        #expect(s.listing("out").isEmpty)
        let symlink = s.path("linked.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        #expect(throws: (any Error).self) { try ArchiveIndex(symlink) }
    }

    @Test func damagedBodyNeverPublishesAnEntry() throws {
        let s = try Scratch()
        let script = #"""
            import zipfile, sys, struct
            path=sys.argv[1]
            with zipfile.ZipFile(path,'w') as z: z.writestr('file.txt','contents')
            with open(path,'r+b') as f:
                header=f.read(30); name,extra=struct.unpack_from('<HH',header,26)
                f.seek(30+name+extra); f.write(b'X')
            """#
        try run("/usr/bin/python3", ["-c", script, s.path("damaged.zip").path])
        let index = try ArchiveIndex(s.path("damaged.zip"))
        #expect(throws: (any Error).self) { try index.extract("file.txt", into: s.path("out"), name: "file.txt") }
        #expect(s.listing("out").isEmpty)
    }

    @MainActor @Test(.isolatedSettings) func openingExtractsFreshBytesAndCompletesActivityBeforeLaunching() async throws {
        let s = try Scratch()
        let file = try archive(s)
        let root = ArchiveLocation(archive: file).url
        let provider = try #require(RemoteFS.provider(for: root))
        let item = try #require(try provider.list(root.appendingPathComponent("src")).first { $0.name == "top.txt" })
        var opened: URL?
        RemoteOpener.open(item) { local in
            #expect(FileOperationsController.shared.activities.last(where: { $0.sources.contains(item.url) })?.state.isEnded == true)
            opened = local
        }
        #expect(await eventually { opened != nil })
        let first = try #require(opened)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        #expect(try String(contentsOf: first, encoding: .utf8) == "top")
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path) == [item.name])
        try "changed".write(to: s.path("src/top.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/zip", ["-q", file.path, "src/top.txt"], in: s.url)
        opened = nil
        RemoteOpener.open(item) { opened = $0 }
        #expect(await eventually { opened != nil })
        let second = try #require(opened)
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        #expect(second != first)
        #expect(try String(contentsOf: second, encoding: .utf8) == "changed")
    }

    @MainActor @Test func archiveSourceListsAndCancelledLoadNeverDelivers() async throws {
        let s = try Scratch()
        let file = try archive(s)
        let root = ArchiveLocation(archive: file).url
        let source = LocationContentSources.source(for: root)
        #expect(source is ArchiveSource)
        var answer: LocationListing?
        let load = source.load(root, expanded: [root.appendingPathComponent("src")]) { answer = $0 }
        #expect(await eventually { answer != nil })
        #expect(answer?.items.count == 1)
        #expect(answer?.children?.values.first?.count == 3)
        load.cancel()
        var delivered = false
        let cancelled = source.load(root, expanded: []) { _ in delivered = true }
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!delivered)
    }
}
