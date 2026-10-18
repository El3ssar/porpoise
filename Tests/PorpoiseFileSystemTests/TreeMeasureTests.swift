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
}
