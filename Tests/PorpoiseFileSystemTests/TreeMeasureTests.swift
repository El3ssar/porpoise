import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseFileSystem

struct TreeMeasureTests {
    @Test func overlappingRootsAndHardLinksAreMeasuredOnceWithIncrementalProgress() throws {
        let s = try Scratch(), file = try s.file("root/sub/a", "hello")
        try FileManager.default.linkItem(at: file, to: s.path("root/sub/hard"))
        try s.file("root/b", "abc")
        var updates: [TreeMeasure.Progress] = []
        let result = try #require(TreeMeasure.measure([s.path("root"), s.path("root/sub"), file], reportInterval: 0) { updates.append($0) })
        #expect(result.bytes == 8 && result.files == 2 && result.folders == 2)
        #expect(result.errors.isEmpty && updates.last == result)
        #expect(updates.map(\.bytes) == updates.map(\.bytes).sorted())
        let allocated = try #require(TreeMeasure.measure([file], policy: .allocated))
        #expect(allocated.bytes == (try PhysicalTreeScanner.entry(file)).allocated)
        #expect(TreeMeasure.measure([s.path("root")], maxDepth: 0)?.bytes == 0)
    }

    @Test func selectedLinksCanFollowTheirTargetButInnerLinksNeverRecurse() throws {
        let s = try Scratch(), file = try s.file("target/file", "abc")
        try s.symlink("selected", to: s.path("target").path)
        try s.symlink("target/loop", to: s.path("target").path)
        let target = try #require(TreeMeasure.measure([s.path("selected")]))
        #expect(target.bytes == 3 && target.folders == 1)
        let link = try #require(TreeMeasure.measure([s.path("selected")], followTopLevelLink: false))
        #expect(link.bytes == 0 && link.files == 1 && link.folders == 0)
        #expect(target.bytes == UsageTree(PhysicalTreeScanner.scan([s.path("target")])).nodes[0].logical)
        let cancellation = DiskCancellation()
        #expect(TreeMeasure.measure([file], cancellation: cancellation, reportInterval: 0) { _ in cancellation.cancel() } == nil)
        #expect(TreeMeasure.measure([file], cancellation: cancellation) == nil)
        #expect(TreeMeasure.measure([URL(string: "sftp://host/folder")!]) == TreeMeasure.Progress())
    }
    @Test func aWideFolderReportsFilesBeforeReadingAllMetadataBatches() throws {
        let scratch = try Scratch()
        let root = try scratch.folder("wide")
        for index in 0..<2048 {
            try scratch.file("wide/\(index)-" + String(repeating: "a", count: 180), "x")
        }
        var checkpoints = 0, firstFileCheckpoint: Int?
        let cancellation = DiskCancellation(checkpoint: { checkpoints += 1 })
        let result = TreeMeasure.measure([root], cancellation: cancellation, reportInterval: 0) { partial in
            if partial.files == 1 {
                firstFileCheckpoint = checkpoints
                cancellation.cancel()
            }
        }
        #expect(result == nil)
        // The first bulk batch, or POSIX fallback's first entry after dot entries. The old
        // collector read every metadata batch (more than ten) before reporting any file.
        #expect(try #require(firstFileCheckpoint) <= 5)
    }

    @Test func streamingTotalsRetainReadErrorsAndFinishWithAllFiles() throws {
        let scratch = try Scratch()
        let root = try scratch.folder("root")
        for index in 0..<1200 { try scratch.file("root/\(index)", "hello") }
        var previous = TreeMeasure.Progress()
        let total = try #require(
            TreeMeasure.measure([root, scratch.path("missing")], reportInterval: 0) { partial in
                #expect(partial.files >= previous.files && partial.bytes >= previous.bytes)
                previous = partial
            })
        #expect(total.files == 1200 && total.bytes == 6000 && total.folders == 1)
        #expect(total.errors.count == 1)
        #expect(previous.files == total.files && previous.bytes == total.bytes)
    }

    @Test func deepStreamingTreesRespectTheDepthLimitWithoutFollowingInnerLinks() throws {
        let scratch = try Scratch()
        let root = try scratch.folder("deep")
        var folder = "deep"
        for _ in 0..<128 {
            folder += "/d"
            try scratch.folder(folder)
            try scratch.file(folder + "/file", "x")
        }
        try scratch.symlink(folder + "/loop", to: root.path)
        let complete = try #require(TreeMeasure.measure([root]))
        #expect(complete.bytes == 128 && complete.files == 129 && complete.folders == 129)
        #expect(complete.errors.isEmpty)
        let limited = try #require(TreeMeasure.measure([root], maxDepth: 3))
        #expect(limited.bytes == 2 && limited.files == 2 && limited.folders == 4)
    }

}
