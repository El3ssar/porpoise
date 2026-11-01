import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor struct SearchCancellationTests {
    private func snippetQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "porpoise.test.search-snippets.\(UUID())"
        queue.maxConcurrentOperationCount = 1
        return queue
    }

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var paths: [String] { lock.withLock { values } }
    }

    @Test func supersededSpotlightBatchStopsBeforeItsNextMetadataRead() async throws {
        let scratch = try Scratch(), reads = Reads()
        let gate = DispatchSemaphore(value: 0)
        let started = AsyncStream.makeStream(of: Void.self)
        let updates = AsyncStream.makeStream(of: [String].self)
        var starts = started.stream.makeAsyncIterator(), results = updates.stream.makeAsyncIterator()
        var delivered: [[String]] = []
        let runner = SearchRunner(text: "file", scope: scratch.url, contents: false) { items, _ in
            delivered.append(items.map(\.name)); updates.continuation.yield(items.map(\.name))
        }
        runner.snippetQueue = snippetQueue()
        runner.loadSpotlightItem = { url in
            reads.append(url.lastPathComponent)
            if url.lastPathComponent == "file-old-0" { started.continuation.yield(); gate.wait() }
            return FileItem(url: url, name: url.lastPathComponent, isDirectory: false)
        }
        defer { gate.signal(); runner.stop(); started.continuation.finish(); updates.continuation.finish() }
        runner.publish((0..<100).map { scratch.path("file-old-\($0)").path }, done: false)
        try #require(await starts.next() != nil)
        #expect(reads.paths == ["file-old-0"])
        runner.publish([scratch.path("file-new").path], done: true)
        gate.signal()
        #expect(await results.next() == ["file-new"])
        #expect(reads.paths == ["file-old-0", "file-new"])
        #expect(delivered == [["file-new"]])
    }

    @Test func cancelledHydrationDoesNotLoseEarlierDirtyPaths() async throws {
        let scratch = try Scratch(), reads = Reads()
        let gate = DispatchSemaphore(value: 0)
        let started = AsyncStream.makeStream(of: Void.self)
        let updates = AsyncStream.makeStream(of: [FileItem].self)
        var starts = started.stream.makeAsyncIterator(), results = updates.stream.makeAsyncIterator()
        var batches: [[FileItem]] = []
        let runner = SearchRunner(text: "file", scope: scratch.url, contents: false) { items, _ in
            batches.append(items); updates.continuation.yield(items)
        }
        runner.snippetQueue = snippetQueue()
        runner.loadSpotlightItem = { url in
            reads.append(url.lastPathComponent)
            if url.lastPathComponent == "block" { started.continuation.yield(); gate.wait() }
            let version = reads.paths.filter { $0 == url.lastPathComponent }.count
            return FileItem(url: url, name: url.lastPathComponent, isDirectory: false, size: Int64(version))
        }
        defer { gate.signal(); runner.stop(); started.continuation.finish(); updates.continuation.finish() }
        let x = scratch.path("x").path, y = scratch.path("y").path
        runner.publish([x], done: true)
        #expect(await results.next()?.first?.size == 1)
        runner.publish([scratch.path("block").path], done: false)
        try #require(await starts.next() != nil)
        runner.publish([x, y], done: true, changed: [x])
        runner.publish([x, y], done: true, changed: [y])
        gate.signal()
        #expect(await results.next()?.count == 2)
        #expect(batches.last?.first(where: { $0.name == "x" })?.size == 2)
    }

    @Test func completedNegativeSnippetReadsSurviveUnrelatedLiveUpdates() async throws {
        let scratch = try Scratch(), reads = Reads()
        var finished = 0
        let completions = AsyncStream.makeStream(of: Int.self)
        var batches = completions.stream.makeAsyncIterator()
        let runner = SearchRunner(text: "needle", scope: scratch.url, contents: true) { _, _ in }
        runner.snippetQueue = snippetQueue()
        runner.loadSpotlightItem = { url in FileItem(url: url, name: url.lastPathComponent, isDirectory: false) }
        runner.readSpotlightText = { path, _, _ in
            reads.append(path); return nil
        }
        runner.onSnippetBatchFinished = {
            finished += 1; completions.continuation.yield(finished)
        }
        defer { runner.stop(); completions.continuation.finish() }
        let first = scratch.path("unsupported.pdf").path, second = scratch.path("barrier.pdf").path
        runner.publish([first], done: true)
        #expect(await batches.next() == 1)
        // A new negative result provides a worker-completion barrier: the prior negative must not be read again.
        runner.publish([first, second], done: true)
        #expect(await batches.next() == 2)
        #expect(reads.paths == [first, second])
        runner.publish([first, second], done: true, changed: [first])
        #expect(await batches.next() == 3)
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
