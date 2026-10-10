import Foundation
import Testing
@testable import PorpoiseCore
import PorpoiseTestSupport

/// Big folders, big trees and bursts of changes. Time bounds are generous (several times what an M-series Mac
/// needs): they catch something quadratic, not a slow machine.
@Suite(.serialized) struct StressTests {
    private let scratch: Scratch

    init() throws { scratch = try Scratch("Stress") }

    /// Creates `count` empty files named by `name(i)` with plain syscalls (fast, and no Foundation name conversion).
    private func makeFiles(in dir: URL, count: Int, name: (Int) -> String) throws {
        for i in 0..<count {
            let fd = open(dir.path + "/" + name(i), O_CREAT | O_WRONLY | O_EXCL, 0o644)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            close(fd)
        }
    }

    private func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    @Test func twentyThousandFilesListSortAndGroup() throws {
        let n = 20_000
        let dir = try scratch.folder("big")
        // Shuffled creation order, so the listing isn't already sorted.
        var rng = SeededGenerator(seed: 20_000)
        let order = Array(1...n).shuffled(using: &rng)
        try makeFiles(in: dir, count: n) { "file \(order[$0]).txt" }
        try scratch.folder("big/a folder")

        var items: [FileItem] = []
        let listTime = try seconds { items = try DirectoryLister.list(dir) }
        #expect(items.count == n + 1)
        #expect(listTime < 20, "listing took \(listTime) s")
        #expect(DirectoryLister.childCount(dir, includeHidden: false) == n + 1)

        var sorted: [FileItem] = []
        let sortTime = seconds { sorted = ItemSorter.sort(items, props: ViewProperties()) }
        #expect(sortTime < 10, "sorting took \(sortTime) s")
        // Natural order is numeric order, folders first.
        #expect(sorted.map(\.name) == ["a folder"] + (1...n).map { "file \($0).txt" })

        var p = ViewProperties(); p.sortRole = .modificationTime; p.sortOrder = .descending
        let byDate = seconds { _ = ItemSorter.sort(items, props: p) }
        #expect(byDate < 10, "sorting by date took \(byDate) s")
        let groupTime = seconds {
            let groups = ItemGrouper.groups(sorted, role: .name, props: ViewProperties())
            #expect(groups.map(\.title) == ["A", "F"])
            #expect(groups.map(\.items.count) == [1, n])
        }
        #expect(groupTime < 10, "grouping took \(groupTime) s")
        let filterTime = try seconds {
            let m = try #require(NameFilter(text: "file 1*7.txt", mode: .glob).matcher())
            #expect(items.filter { m($0.name) }.count == (1...n).filter { "\($0)".hasPrefix("1") && "\($0)".hasSuffix("7") }.count)
        }
        #expect(filterTime < 10)
    }

    /// A tree of a few thousand small files is copied completely, with progress reaching the total; a cancelled
    /// copy leaves nothing behind.
    @Test func copyingAThousandsOfFilesTree() throws {
        let src = try scratch.folder("tree")
        var total: Int64 = 0
        for d in 0..<40 {
            let sub = try scratch.folder("tree/dir \(d)/nested")
            for f in 0..<50 {
                let text = "\(d)-\(f)"
                try Data(text.utf8).write(to: (f % 2 == 0 ? sub : sub.deletingLastPathComponent()).appendingPathComponent("f\(f)"))
                total += Int64(text.utf8.count)
            }
        }
        #expect(FileJob.diskSize(src) == total)
        let dst = try scratch.folder("copy")
        let job = FileJob(kind: .copy, sources: [src], destinationFolder: dst)
        var last: JobProgress?
        job.onProgress = { last = $0 }
        let time = try seconds { _ = try job.run() }
        #expect(time < 20, "copy took \(time) s")
        #expect(job.errors.isEmpty, "\(job.errors)")
        #expect(FileJob.diskSize(dst.appendingPathComponent("tree")) == total)
        #expect(last?.doneBytes == total && last?.totalBytes == total)
        #expect(scratch.read("copy/tree/dir 39/nested/f48") == "39-48")
        #expect(scratch.read("copy/tree/dir 0/f1") == "0-1")

        // Cancelled from another thread (as the UI does) while copying: never a partial tree. Clones report no
        // progress, so the cancel may also land after the copy finished; then the copy is complete.
        let dst2 = try scratch.folder("copy2")
        let cancelled = FileJob(kind: .copy, sources: [src], destinationFolder: dst2)
        var started = false
        cancelled.onProgress = { _ in
            guard !started else { return }
            started = true
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { cancelled.cancel() }
        }
        _ = try cancelled.run()
        if scratch.listing("copy2").isEmpty {
            #expect(cancelled.isCancelled && cancelled.results.isEmpty)
        } else {
            #expect(FileJob.diskSize(dst2) == total && cancelled.results.count == 1)
        }
        #expect(cancelled.errors.isEmpty, "\(cancelled.errors)")

        // Moving the whole tree within the volume is a rename: fast, and nothing is left at the source.
        let moved = try scratch.folder("moved")
        let move = FileJob(kind: .move, sources: [dst.appendingPathComponent("tree")], destinationFolder: moved)
        let moveTime = try seconds { _ = try move.run() }
        #expect(moveTime < 5)
        #expect(scratch.listing("copy").isEmpty)
        #expect(FileJob.diskSize(moved) == total)
    }

    /// A burst of thousands of changes is reported, and the watcher still reports the next change after it.
    @Test func folderWatcherKeepsUpWithABurst() throws {
        let dir = try scratch.folder("watched")
        let other = try scratch.folder("other")
        Thread.sleep(forTimeInterval: 0.2)   // events of creating them are not part of the test
        let lock = NSLock()
        var hits: [Set<String>] = []
        let watcher = FolderWatcher { h in lock.lock(); hits.append(h); lock.unlock() }
        watcher.watch([dir, other])
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        func seen() -> Set<String> { lock.lock(); defer { lock.unlock() }; return hits.reduce(into: []) { $0.formUnion($1) } }
        func reset() { lock.lock(); hits = []; lock.unlock() }

        try makeFiles(in: dir, count: 3000) { "burst \($0)" }
        for i in stride(from: 0, to: 3000, by: 2) { unlink(dir.path + "/burst \(i)") }
        #expect(waitUntil(10) { seen().contains(dir.path) })

        // Let the burst drain, then one more change must still come through.
        Thread.sleep(forTimeInterval: 1)
        reset()
        try Data("x".utf8).write(to: other.appendingPathComponent("after"))
        #expect(waitUntil(10) { seen() == [other.path] })

        // Rewatching many folders at once (as a window with many tabs does) and changing all of them.
        let many = try (0..<50).map { try scratch.folder("many/\($0)") }
        watcher.watch(many)
        Thread.sleep(forTimeInterval: 0.3)
        reset()
        for f in many { try Data("y".utf8).write(to: f.appendingPathComponent("y")) }
        #expect(waitUntil(10) { seen() == Set(many.map(\.path)) }, "\(many.count - seen().count) folders not reported")
    }
}
