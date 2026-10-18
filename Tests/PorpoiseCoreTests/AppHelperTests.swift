import Foundation
import Testing

@testable import PorpoiseCore

/// Helpers the app target uses, kept in Core so they're tested.
@Suite struct AppHelperTests {
    @Test func playbackTimeSwitchesToHoursAtOneHourAndRoundsDown() {
        #expect(FileFormat.playbackTime(0) == "0:00")
        #expect(FileFormat.playbackTime(59.9) == "0:59")
        #expect(FileFormat.playbackTime(60) == "1:00")
        #expect(FileFormat.playbackTime(3599.99) == "59:59")
        #expect(FileFormat.playbackTime(3600) == "1:00:00")
        #expect(FileFormat.playbackTime(36_061) == "10:01:01")
    }

    @Test func commonFolderIsTheDeepestSharedParent() {
        func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
        #expect(PathMath.commonFolder(of: [u("/a/b/c.txt")]).path == "/a/b")
        #expect(PathMath.commonFolder(of: [u("/a/b/c.txt"), u("/a/b/d.txt")]).path == "/a/b")
        #expect(PathMath.commonFolder(of: [u("/a/b/c/x"), u("/a/b/d/y"), u("/a/b/c/z")]).path == "/a/b")
        #expect(PathMath.commonFolder(of: [u("/a/x"), u("/b/y")]).path == "/")
        // "..": compared after standardizing, and a name that only starts alike isn't a shared folder.
        #expect(PathMath.commonFolder(of: [u("/a/b/../c/x"), u("/a/c/y")]).path == "/a/c")
        #expect(PathMath.commonFolder(of: [u("/a/bc/x"), u("/a/b/y")]).path == "/a")
        #expect(PathMath.commonFolder(of: [u("/a/b/c.txt")]).hasDirectoryPath)
    }

}
