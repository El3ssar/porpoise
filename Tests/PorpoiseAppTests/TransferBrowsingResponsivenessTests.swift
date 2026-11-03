import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Progress must repaint the incoming item without turning each tick into a folder reload.
@MainActor @Suite(.serialized, .isolatedSettings) struct TransferBrowsingResponsivenessTests {
    @Test func progressRepaintsWithoutRelayoutOrListingNotifications() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch("transfer-browsing")
        let folder = URL(fileURLWithPath: scratch.url.path, isDirectory: true)
        Settings.shared.showGitStatus = false
        Settings.shared.folderSizeMode = .none
        let pane = ViewContainer(url: folder)
        pane.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        try #require(await eventually { !pane.model.isLoading })
        let items = (0..<2001).map { index in
            FileItem(url: scratch.path("file-\(index).txt"), name: "file-\(index).txt", isDirectory: false, size: 1000)
        }
        pane.model.props.mode = .compact
        pane.model.props.setRoles([.size], for: .compact)
        pane.model.applyEdit(ListingEdit(folder: scratch.url, added: items))
        let incoming = FileItem(url: scratch.path("incoming.txt"), name: "incoming.txt", isDirectory: false, size: 1000)
        let activity = Activity(kind: .copy, sources: [], destination: scratch.url, job: nil)
        activity.state = .running
        activity.incomingItem = incoming
        FileOperationsController.shared.activities.append(activity)
        defer {
            FileOperationsController.shared.activities.removeAll { $0 === activity }
            NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        }
        NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        try #require(await eventually { !pane.model.isLoading && pane.model.index(of: incoming.url) != nil })
        pane.list.computeLayout()
        try #require(await eventually { !pane.list.isPreparingCompact && pane.list.frames.count == pane.model.rows.count })
        let incomingIndex = try #require(pane.model.index(of: incoming.url))
        let label = pane.list.nameTextRect(incomingIndex)
        #expect(pane.list.incomingProgressRedrawRect(incomingIndex).contains(CGPoint(x: label.midX, y: label.maxY + 6)))
        pane.model.selection = [items[0].url]
        let revision = pane.model.rowsRevision
        let measurements = pane.list.textMeasurementCount
        let frames = Array(pane.list.frames)
        var reloads = 0
        let observer = NotificationCenter.default.addObserver(forName: ViewContainer.listingReloaded, object: pane, queue: .main) { _ in
            MainActor.assumeIsolated { reloads += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let start = ProcessInfo.processInfo.systemUptime
        for bytes in 1...100 {
            activity.progress?.doneBytes = Int64(bytes)
            NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        }
        print("TRANSFER_BROWSING 100 progress ticks ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        #expect(pane.model.incomingProgress[incoming.url] == 0.1)
        #expect(pane.model.rowsRevision == revision)
        #expect(pane.model.selection == [items[0].url])
        #expect(Array(pane.list.frames) == frames)
        #expect(pane.list.textMeasurementCount == measurements)
        #expect(reloads == 0)
        #expect(pane.window == nil)
        activity.incomingItem = nil
        NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        try #require(await eventually { !pane.model.isLoading && pane.model.index(of: incoming.url) == nil })
        #expect(pane.model.incomingProgress.isEmpty)
        #expect(reloads > 0)
    }

    @Test(.timeLimit(.minutes(1))) func browsingAndNewSearchResultsProceedWhilePreviewAndContentReadsWait() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch("busy-browsing")
        let folder = URL(fileURLWithPath: scratch.url.path, isDirectory: true)
        Settings.shared.showGitStatus = false
        Settings.shared.previewRemote = true
        let pane = ViewContainer(url: folder)
        pane.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        try #require(await eventually { !pane.model.isLoading })
        pane.model.props.mode = .details
        let items = (0..<2001).map {
            FileItem(url: scratch.path("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false)
        }
        pane.model.applyEdit(ListingEdit(folder: folder, added: items))
        try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == items.count })
        pane.model.selection = [items[1].url]

        let remote = URL(string: "sftp://busy-\(UUID().uuidString.lowercased()).invalid/")!
        let server = GatedServer(png: ThumbnailSchedulingTests.png)
        RemoteFS.use(server, for: remote)
        defer { server.open(); RemoteFS.use(nil, for: remote) }
        let thumbnails = Thumbnails(), owner = ThumbnailSchedulingTests.Viewport()
        owner.shown = 0..<1
        let image = FileItem(url: remote.appendingPathComponent("item-0.png"), name: "item-0.png", isDirectory: false, size: 100)
        _ = thumbnails.thumbnail(for: image, size: 64, owner: owner)
        try #require(await eventually { server.started == 1 })

        let textGate = DispatchSemaphore(value: 0)
        let reading = AsyncStream.makeStream(of: Void.self)
        var reads = reading.stream.makeAsyncIterator()
        let results = DirectoryModel(location: folder, prefetchFolders: false)
        weak var activeRunner: SearchRunner?
        let runner = SearchRunner(text: "needle", scope: folder, contents: true) { items, _ in
            guard let activeRunner else { return }
            let matches = SearchMatches(text: "needle", contents: true, snippets: activeRunner.snippets)
            results.sortSearchResults(items) { apply in
                results.searchMatches = matches; apply()
            }
        }
        activeRunner = runner
        let snippetQueue = OperationQueue()
        snippetQueue.maxConcurrentOperationCount = 1
        runner.snippetQueue = snippetQueue
        runner.loadSpotlightItem = { FileItem(url: $0, name: $0.lastPathComponent, isDirectory: false, size: 1) }
        runner.readSpotlightText = { _, _, _ in
            reading.continuation.yield(); textGate.wait(); return "a needle in the text"
        }
        defer { runner.stop(); snippetQueue.cancelAllOperations(); textGate.signal(); reading.continuation.finish() }
        let paths = [scratch.path("needle.txt").path, scratch.path("body.txt").path]
        runner.publish(paths, done: true)
        try #require(await reads.next() != nil)
        try #require(await eventually { results.rows.count == 2 })
        results.selection = [scratch.path("needle.txt")]
        let activity = Activity(kind: .copy, sources: [], destination: folder, job: nil)
        activity.state = .running
        activity.incomingItem = FileItem(url: items[1].url, name: items[1].name, isDirectory: false, size: 1000)
        FileOperationsController.shared.activities.append(activity)
        defer {
            FileOperationsController.shared.activities.removeAll { $0 === activity }
            NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        }
        NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        try #require(await eventually { !pane.model.isLoading && pane.model.incomingProgress[items[1].url] != nil })
        let revision = pane.model.rowsRevision
        for bytes in 1...100 {
            activity.progress?.doneBytes = Int64(bytes)
            NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        }
        #expect(pane.model.rowsRevision == revision && pane.model.incomingProgress[items[1].url] == 0.1)
        // Snapshot fresh metadata while the prior snippet and preview are still waiting on IO.
        runner.loadSpotlightItem = { FileItem(url: $0, name: $0.lastPathComponent, isDirectory: false, size: 2) }
        runner.publish(paths, done: true, changed: Set(paths))
        pane.model.props.sortOrder = .descending
        pane.model.filter = NameFilter(text: "file-1")
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        try #require(
            await eventually {
                heartbeat && !pane.model.isLoading && results.rows.count == 2 && results.rows.allSatisfy { $0.item.size == 2 }
            })
        #expect(pane.model.rows.allSatisfy { $0.item.name.contains("file-1") })
        #expect(pane.model.selection == [items[1].url])
        #expect(results.rows.map(\.item.name) == ["needle.txt", "body.txt"])
        #expect(results.groups.map(\.title) == ["Name matches", "Content matches"])
        #expect(results.selection == [scratch.path("needle.txt")])
        #expect(thumbnails.scheduler.runningCount(.server) == 1 && server.started == 1)
        #expect(pane.window == nil)
        // The newer snippet reader is no longer gated; the cancelled old result must not overwrite it.
        runner.readSpotlightText = { _, _, _ in "new needle snippet" }
        runner.publish(paths, done: true)
        textGate.signal()
        server.open()
        try #require(await eventually { thumbnails.outstanding == 0 && runner.snippets[scratch.path("body.txt")] == "new needle snippet" })
        #expect(server.peak == 1 && server.fetched == ["item-0.png"])
        #expect(thumbnails.thumbnail(for: image, size: 64, owner: owner) != nil)
    }

    @Test func standaloneModelKeepsChangeCallbackAndSkipsUnchangedFractions() throws {
        let scratch = try Scratch("transfer-progress-fallback")
        let model = DirectoryModel(location: URL(fileURLWithPath: scratch.url.path, isDirectory: true), prefetchFolders: false)
        let item = FileItem(url: scratch.path("incoming.txt"), name: "incoming.txt", isDirectory: false, size: 100)
        let activity = Activity(kind: .copy, sources: [], destination: scratch.url, job: nil)
        activity.state = .running
        activity.incomingItem = item
        FileOperationsController.shared.activities.append(activity)
        defer { FileOperationsController.shared.activities.removeAll { $0 === activity } }
        var changes = 0
        model.onChange = { changes += 1 }
        NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        #expect(model.rows.map(\.item.url) == [item.url])
        changes = 0
        activity.progress?.doneBytes = 10
        NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        #expect(changes == 1 && model.incomingProgress[item.url] == 0.1)
        NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        #expect(changes == 1)
    }
}
