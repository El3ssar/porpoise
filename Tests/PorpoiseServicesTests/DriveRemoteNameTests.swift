import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Drive names may hold "/" (or be ".." with more after it): copied or cached on this Mac, each stays one item
/// inside its destination, its "/" shown as Finder shows a ":" in a name.
extension DriveMutationTests {
    @Test func remoteNamesStayInsideTheLocalDestination() async throws {
        let server = try server(), scratch = try Scratch()
        let client = try client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let folder = try await client.createFolder(name: "Folder", parentID: "root")
        let child = try await client.upload(try scratch.file("up/child.txt", "inside"), parentID: folder.id)
        let first = try await client.upload(try scratch.file("up/first.txt", "first"), parentID: "root")
        let second = try await client.upload(try scratch.file("up/second.txt", "second"), parentID: "root")
        let renames: [(String, String)] = [
            (folder.id, "../escape"), (child.id, "../child.txt"), (first.id, "../first.txt"), (second.id, "../\u{301}second.txt"),
        ]
        try await server.control(["remoteChanges": renames.map { ["fileId": $0.0, "file": ["name": $0.1]] }])
        func url(_ id: String) async throws -> URL { try await client.file(id).location(accountID: client.accountID).url }
        let output = try scratch.folder("area/output")
        func copy(_ sources: [URL]) async -> RemoteTransferJob {
            let job = RemoteTransferJob(
                kind: .copy, sources: sources, destination: output,
                control: JobControl(), rule: .keepBoth, options: .init())
            await offThePool { job.run() }
            return job
        }
        // A folder (the ordered path) and several small files (the parallel path).
        let folderJob = await copy([try await url(folder.id)])
        #expect(folderJob.errors.isEmpty, "\(folderJob.errors)")
        let filesJob = await copy([try await url(first.id), try await url(second.id)])
        #expect(filesJob.errors.isEmpty, "\(filesJob.errors)")
        let fm = FileManager.default
        #expect(try fm.contentsOfDirectory(atPath: scratch.path("area").path) == ["output"])
        #expect(Set(try fm.contentsOfDirectory(atPath: scratch.url.path)) == ["journal", "up", "area"])
        #expect(Set(try fm.contentsOfDirectory(atPath: output.path)) == ["..:escape", "..:first.txt", "..:\u{301}second.txt"])
        #expect(scratch.read("area/output/..:escape/..:child.txt") == "inside")
        #expect(scratch.read("area/output/..:first.txt") == "first")
    }

    @Test func previewCacheNamesStayInsideTheCache() async throws {
        let scratch = try Scratch()
        let directory = scratch.url.appendingPathComponent("cache")
        let cache = DriveMediaCache(accountID: UUID(), directory: directory)
        let input = try scratch.file("movie", "frames")
        for name in ["../\u{301}x.mov", "../escape.mov", "a/b.mov"] {
            let stored = try await cache.importFile(input, key: "key-\(name)", name: name)
            #expect(stored.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"), "\(name)")
            #expect(RemoteParsing.isSafeName(stored.lastPathComponent) && stored.lastPathComponent.unicodeScalars.contains(":"), "\(name)")
        }
        for name in ["", ".", "..", "nul\0"] {
            await #expect(throws: DriveError.invalidResponse) { try await cache.importFile(input, key: "bad", name: name) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).sorted() == ["cache", "movie"])
    }
}
