import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveSpeedTests {
    private func fixture(_ scratch: Scratch, files: [[String: Any]], children: [String: [String]] = [:]) throws -> URL {
        return try FakeDriveServer.writeFixture(
            in: scratch,
            [
                "files": files, "children": children, "rootIDs": files.filter { $0["shortcutDetails"] != nil }.map { $0["id"]! },
                "profile": ["sub": "speed", "email": "speed@example.invalid", "name": "Speed fixture"], "drives": [],
            ])
    }

    @Test func latencyCacheAndBoundedShortcuts() async throws {
        let scratch = try Scratch()
        var files: [[String: Any]] = []
        for index in 0..<50 {
            files.append([
                "id": "shortcut-\(index)", "name": "Shortcut \(index)", "mimeType": "application/vnd.google-apps.shortcut",
                "shortcutDetails": ["targetId": "target-\(index)"],
            ])
            files.append(["id": "target-\(index)", "name": "Target \(index)", "mimeType": "application/vnd.google-apps.folder"])
        }
        let server = try FakeDriveServer(fixture: fixture(scratch, files: files), latencyMS: 300)
        let (client, _, _) = try server.client()
        let provider = DriveProvider(accountID: client.accountID, client: client)
        let root = DriveLocation(accountID: client.accountID).url
        let start = Date()
        let baseline = try await client.list(DriveLocation(accountID: client.accountID))
        for file in baseline { _ = try await client.resolve(file) }
        let before = Date().timeIntervalSince(start)
        // The fake holds the shortcut resolutions until two overlap: a bounded-parallel refresh shows it, a serial one can't.
        try await server.control(["holdRequests": 2, "holdPath": "/files/target-"])
        let coldStart = Date()
        let rows = try await provider.refresh(root)
        let cold = Date().timeIntervalSince(coldStart)
        #expect(rows.count == 50 && rows.allSatisfy(\.isBrowsableFolder))
        let concurrent = try #require(try await server.stats()["maxConcurrentRequests"] as? Int)
        #expect(concurrent > 1 && concurrent <= 8)
        let requestCount = try #require(try await server.stats()["requests"] as? [String]).count
        let cacheStart = Date()
        #expect(provider.cachedListing(root) == rows)
        let warm = Date().timeIntervalSince(cacheStart)
        print("DRIVE_SPEED 300ms/request: sequential=\(before)s bounded=\(cold)s cached=\(warm * 1000)ms concurrent=\(concurrent)")
        // The cached listing asks the server nothing.
        #expect(try #require(try await server.stats()["requests"] as? [String]).count == requestCount)
        provider.invalidate(folder: root)
        #expect(provider.cachedListing(root) == nil)
        #expect(provider.cachedListing(DriveLocation(accountID: UUID()).url) == nil)
    }

    @Test @MainActor func prefetchedExpansionAndRefreshKeepSelection() async throws {
        let server = try FakeDriveServer(latencyMS: 300)
        let (client, _, _) = try server.client()
        let provider = DriveProvider(accountID: client.accountID, client: client)
        let root = DriveLocation(accountID: client.accountID).url
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let rows = try await provider.refresh(root)
        let folder = try #require(rows.first { $0.name == "Project Atlas" })
        await provider.prefetch([folder.url])
        let model = DirectoryModel(location: root)
        model.props.mode = .details
        let start = Date()
        model.reload()
        model.setExpanded(folder.url, true)
        #expect(model.items == rows && !model.isLoading)
        #expect(model.rows.contains { $0.depth == 1 })
        // Painted and expanded synchronously from the cache (the checks above ran with no suspension in between).
        let elapsed = Date().timeIntervalSince(start)
        print("DRIVE_SPEED cached DirectoryModel paint + prefetched expansion=\(elapsed * 1000)ms, blocking requests=0")
        let selected = try #require(rows.first { $0.name == "report.txt" }).url
        model.selection = [selected]
        let fixtureURL = FakeDriveServer.fixture("metadata.json")
        var changed = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        var changedFiles = try #require(changed["files"] as? [[String: Any]])
        changedFiles[2]["name"] = "Updated report.txt"
        changed["files"] = changedFiles
        var request = URLRequest(url: server.base.appendingPathComponent("__fixture"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: changed)
        _ = try await URLSession.shared.data(for: request)
        var completed = false
        model.onLoaded = { completed = true }
        // Cache callbacks run immediately, then the complete background diff arrives later.
        model.reload()
        completed = false
        _ = await poll { completed }
        #expect(completed)
        #expect(model.items.contains { $0.name == "Updated report.txt" })
        #expect(model.selection == [selected] && model.expanded.contains(folder.url))
        server.stop()
        model.reload()
        completed = false
        _ = await poll { completed }
        #expect(completed && model.loadError == nil && !model.items.isEmpty)
        model.prefetch(folder)
        model.prefetch(nil)
        provider.invalidate()
        #expect(provider.cachedListing(root) == nil && provider.cachedListing(folder.url) == nil)

    }

    @Test func mediaCacheThumbnailsPreviewAndInvalidation() async throws {
        let scratch = try Scratch()
        let url = try fixture(
            scratch,
            files: [
                [
                    "id": "image", "name": "Photo.png", "mimeType": "image/png", "size": "13", "thumbnailLink": "{base}/thumbnail/image",
                    "hasThumbnail": true,
                ],
                ["id": "native", "name": "Notes", "mimeType": "application/vnd.google-apps.document"],
            ])
        let server = try FakeDriveServer(fixture: url)
        let (client, _, _) = try server.client()
        let file = try await client.file("image")
        let thumbnail = try await client.thumbnail(file)
        #expect(try Data(contentsOf: thumbnail).starts(with: [137, 80, 78, 71]))
        #expect(try await client.thumbnail(file) == thumbnail)
        let requests = try #require(try await server.stats()["requests"] as? [String])
        #expect(requests.filter { $0 == "/thumbnail/image" }.count == 1)
        let native = try await client.file("native")
        #expect(try await client.thumbnail(native).pathExtension == "pdf")
        #expect(try await client.preview(file).lastPathComponent == "Photo.png")
        var untrusted = file
        untrusted.thumbnailLink = URL(string: "https://example.invalid/steal")
        await #expect(throws: DriveError.invalidResponse) { try await client.thumbnail(untrusted) }
        untrusted.thumbnailLink = nil
        untrusted.hasThumbnail = false
        #expect(try await client.thumbnail(untrusted).lastPathComponent == "Photo.png")
        await client.clearCaches()
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
        #expect(client.cachedFile(for: file.location(accountID: client.accountID).url) == nil)
    }

    /// The cache keeps a running total between walks: it still evicts down to its limit, oldest first.
    @Test func runningTotalStillEvictsToTheLimit() async throws {
        let scratch = try Scratch(), folder = scratch.url.appendingPathComponent("cache")
        let cache = DriveMediaCache(accountID: UUID(), directory: folder, byteLimit: 6)
        var files: [URL] = []
        for n in 0..<10 {
            files.append(try await cache.file(key: "k\(n)", name: "f\(n)") { Data([UInt8(n), 0]) })
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(n - 100))], ofItemAtPath: files[n].path)
        }
        let kept = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(kept == Array(files.suffix(3)))
    }

    @Test func diskLRUAndUnsafeNames() async throws {
        let scratch = try Scratch()
        let cache = DriveMediaCache(accountID: UUID(), directory: scratch.url.appendingPathComponent("cache"), byteLimit: 6)
        let first = try await cache.file(key: "first", name: "first.png") { Data([1, 2, 3, 4]) }
        #expect(try await cache.file(key: "first", name: "first.png") { throw DriveError.notFound } == first)
        let second = try await cache.file(key: "second", name: "second.png") { Data([5, 6, 7, 8]) }
        #expect(!FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
        await #expect(throws: DriveError.invalidResponse) { try await cache.file(key: "bad", name: "..") { Data() } }
        await #expect(throws: DriveError.invalidResponse) { try await cache.file(key: "large", name: "large") { Data(count: 7) } }
        let started = Flag(), release = Flag()
        let pending = Task {
            try await cache.file(key: "pending", name: "pending") {
                started.set()
                while !release.isSet { try await Task.sleep(for: .milliseconds(10)) }
                return Data([1])
            }
        }
        // Cleared while the fetch is under way (it finishes only once the clear is done).
        #expect(await poll { started.isSet })
        await cache.clear()
        release.set()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }
}
