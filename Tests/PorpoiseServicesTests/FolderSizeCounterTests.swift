import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct FolderSizeCounterTests {
    @Test func incrementalTotalsIncludeHiddenFilesAndPackages() throws {
        let s = try Scratch()
        try s.file("root/.hidden", "abc")
        try s.file("root/App.app/Contents/data", "hello")
        try s.folder("root/empty")
        var updates: [TreeMeasure.Progress] = []
        let result = try #require(
            TreeMeasure.measure([s.path("root")], cancellation: DiskCancellation(), reportInterval: 0) {
                updates.append($0)
            })
        #expect(result.bytes == 8)
        #expect(result.files == 2)
        #expect(result.folders == 4)
        #expect(updates.count == result.items)
        #expect(updates.last == result)
        #expect(updates.first?.items == 1)
        for (before, after) in zip(updates, updates.dropFirst()) {
            #expect(after.items == before.items + 1)
            #expect(after.bytes >= before.bytes)
        }
    }

    @Test func cancellationFromProgressStopsBeforeRemainingEntriesAndRoots() throws {
        let s = try Scratch()
        for i in 0..<20 { try s.file("root/f\(i)", "12345") }
        let cancellation = DiskCancellation()
        var updates = 0
        let result = TreeMeasure.measure([s.path("root"), s.path("root/f0")], cancellation: cancellation, reportInterval: 0) { value in
            updates += 1
            if value.files == 1 { cancellation.cancel() }
        }
        #expect(result == nil)
        #expect(updates == 2)  // Selected root, then one child.
        var reportedAfterCancellation = false
        #expect(TreeMeasure.measure([s.path("root")], cancellation: cancellation) { _ in reportedAfterCancellation = true } == nil)
        #expect(!reportedAfterCancellation)
    }

    @Test func throttlingDoesNotLoseFinalTotalsAndRecalculationStartsFresh() throws {
        let s = try Scratch()
        let a = try s.file("a", "123")
        let b = try s.file("b", "4567")
        var reports = 0
        let result = try #require(
            TreeMeasure.measure([a, b, s.path("missing")], cancellation: DiskCancellation(), reportInterval: 3600) { _ in
                reports += 1
            })
        #expect(reports == 0)
        #expect(result.bytes == 7 && result.files == 2 && result.folders == 0)
        try Data("123456".utf8).write(to: a)
        #expect(TreeMeasure.measure([a, b], cancellation: DiskCancellation())?.bytes == 10)
        #expect(TreeMeasure.measure([], cancellation: DiskCancellation()) == TreeMeasure.Progress())
    }

    @Test func directorySymlinksAreNotTraversed() throws {
        let s = try Scratch()
        try s.file("outside/data", "must not be counted")
        try s.folder("root")
        let link = s.path("root/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: s.path("outside"))
        let result = try #require(TreeMeasure.measure([s.path("root")], cancellation: DiskCancellation()))
        #expect(result.files == 1 && result.folders == 1)
        let selectedLink = try #require(TreeMeasure.measure([link], cancellation: DiskCancellation()))
        #expect(selectedLink.files == 1 && selectedLink.folders == 1)
        #expect(selectedLink.bytes == Int64("must not be counted".utf8.count))
    }
}
