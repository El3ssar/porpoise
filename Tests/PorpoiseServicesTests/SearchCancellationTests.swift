import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor struct SearchCancellationTests {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var paths: [String] { lock.withLock { values } }
    }

    @Test func supersededSpotlightBatchStopsBeforeItsNextMetadataRead() async throws {
        let scratch = try Scratch(), reads = Reads()
        let gate = DispatchSemaphore(value: 0)
        var delivered: [[String]] = []
        let runner = SearchRunner(text: "file", scope: scratch.url, contents: false) { items, _ in delivered.append(items.map(\.name)) }
        runner.loadSpotlightItem = { url in
            reads.append(url.lastPathComponent)
            if url.lastPathComponent == "file-old-0" { _ = gate.wait(timeout: .now() + 10) }
            return FileItem(url: url, name: url.lastPathComponent, isDirectory: false)
        }
        defer { gate.signal(); runner.stop() }
        runner.publish((0..<100).map { scratch.path("file-old-\($0)").path }, done: false)
        try #require(await eventually { reads.paths == ["file-old-0"] })
        runner.publish([scratch.path("file-new").path], done: true)
        gate.signal()
        try #require(await eventually { delivered.last == ["file-new"] })
        #expect(reads.paths == ["file-old-0", "file-new"])
        #expect(delivered == [["file-new"]])
    }

    @Test func cancelledHydrationDoesNotLoseEarlierDirtyPaths() async throws {
        let scratch = try Scratch(), reads = Reads()
        let gate = DispatchSemaphore(value: 0)
        var batches: [[FileItem]] = []
        let runner = SearchRunner(text: "file", scope: scratch.url, contents: false) { items, _ in batches.append(items) }
        runner.loadSpotlightItem = { url in
            reads.append(url.lastPathComponent)
            if url.lastPathComponent == "block" { _ = gate.wait(timeout: .now() + 10) }
            let version = reads.paths.filter { $0 == url.lastPathComponent }.count
            return FileItem(url: url, name: url.lastPathComponent, isDirectory: false, size: Int64(version))
        }
        defer { gate.signal(); runner.stop() }
        let x = scratch.path("x").path, y = scratch.path("y").path
        runner.publish([x], done: true)
        try #require(await eventually { batches.last?.first?.size == 1 })
        runner.publish([scratch.path("block").path], done: false)
        try #require(await eventually { reads.paths.contains("block") })
        runner.publish([x, y], done: true, changed: [x])
        runner.publish([x, y], done: true, changed: [y])
        gate.signal()
        try #require(await eventually { batches.last?.count == 2 })
        #expect(batches.last?.first(where: { $0.name == "x" })?.size == 2)
    }

    @Test func completedNegativeSnippetReadsSurviveUnrelatedLiveUpdates() async throws {
        let scratch = try Scratch(), reads = Reads()
        var finished = 0
        let runner = SearchRunner(text: "needle", scope: scratch.url, contents: true) { _, _ in }
        runner.loadSpotlightItem = { url in FileItem(url: url, name: url.lastPathComponent, isDirectory: false) }
        runner.readSpotlightText = { path, _, _ in
            reads.append(path); return nil
        }
        runner.onSnippetBatchFinished = { finished += 1 }
        defer { runner.stop() }
        let first = scratch.path("unsupported.pdf").path, second = scratch.path("barrier.pdf").path
        runner.publish([first], done: true)
        try #require(await eventually { finished == 1 })
        // A new negative result provides a worker-completion barrier: the prior negative must not be read again.
        runner.publish([first, second], done: true)
        try #require(await eventually { finished == 2 })
        #expect(reads.paths == [first, second])
        runner.publish([first, second], done: true, changed: [first])
        try #require(await eventually { finished == 3 })
        #expect(reads.paths == [first, second, first])
    }

    @Test func cancelledSnippetBatchNeverReadsTheNextFile() throws {
        let cancellation = DiskCancellation()
        var reads: [String] = []
        let result = FolderSearch.lines(
            in: ["first", "second", "third"], spec: try SearchSpec("needle", contents: true),
            cancelled: { cancellation.isCancelled },
            read: { path, _, _ in
                reads.append(path)
                cancellation.cancel()
                return "needle"
            })
        #expect(reads == ["first"])
        #expect(result.isEmpty)
    }

    @Test func boundedTextReaderChecksCancellationBetweenChunks() throws {
        let scratch = try Scratch()
        let file = try scratch.file("text", String(repeating: "text\n", count: 100_000))
        var checks = 0
        let text = IndexFileText.read(
            file.path, limit: 1_000_000,
            cancelled: {
                checks += 1
                return checks >= 4
            })
        #expect(text == nil)
        #expect(checks >= 4)
    }
}
