import Foundation
import Testing

@testable import PorpoiseFileSystem

/// W-236 (W-235 W15): which paths are on a network file system, from the mount table, without touching them.
@Suite struct MountTableTests {
    @Test func localPathsAreLocalAndAutomountsAreNot() {
        #expect(!MountTable.isNetwork("/"))
        #expect(!MountTable.isNetwork(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(!MountTable.isNetwork(NSTemporaryDirectory()))
        // macOS mounts /System/Volumes/Data/home with autofs (auto_home), a file system that isn't local.
        let mounts = (try? String(contentsOfFile: "/etc/auto_master", encoding: .utf8)) ?? ""
        if mounts.contains("auto_home") { #expect(MountTable.isNetwork("/System/Volumes/Data/home/someone")) }
    }
}
