import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Disks on Desktop Mode's desktop: listed first, and never moved, trashed or deleted by any file operation.
@MainActor @Suite(.isolatedSettings) struct DesktopVolumeTests {
    private let root = URL(fileURLWithPath: "/", isDirectory: true)

    @Test func leadingItemsComeFirstUnsortedAndSurviveReloads() async throws {
        let s = try Scratch()
        try s.file("b.txt"); try s.file("a.txt")
        let m = try await DirectoryModel.loaded(s.url)
        let disks = [
            FileItem(url: URL(fileURLWithPath: "/Volumes/Zed"), name: "Zed", isDirectory: true),
            FileItem(url: root, name: "Mac", isDirectory: true),
        ]
        m.leadingItems = disks
        #expect(m.rowNames == ["Zed", "Mac", "a.txt", "b.txt"])
        #expect(m.index(of: root) == 1)
        m.selection = [root]
        m.reload()
        try #require(await eventually { !m.isLoading })
        #expect(m.rowNames == ["Zed", "Mac", "a.txt", "b.txt"] && m.selection == [root])
        // Sorting and filtering the files leaves the disks where they are.
        m.props.sortOrder = .descending
        #expect(m.rowNames == ["Zed", "Mac", "b.txt", "a.txt"])
        m.leadingItems = []
        #expect(m.rowNames == ["b.txt", "a.txt"] && m.selection.isEmpty)
    }

    @Test func aDiskIsNeverMovedTrashedOrDeletedButTheRestOfTheSelectionIs() async throws {
        let s = try Scratch()
        // A stand-in disk: the guard is told this scratch folder is mounted, so a broken guard can only reach scratch.
        let disk = try s.folder("USB"), keep = try s.file("USB/keep.txt", "kept")
        let file = try s.file("keep moving.txt"), destination = try s.folder("Destination")
        let ui = ScriptedUI(), controller = makeController(ui)
        controller.volumeRoots = { [disk.standardizedFileURL.path] }
        var started: [[URL]] = []
        ui.onJobStarted = { started.append($0.sources) }
        let moved = try await controller.perform(.move, [disk, file], to: destination)
        #expect(moved.map(\.lastPathComponent) == ["keep moving.txt"])
        #expect(started == [[file]])
        #expect(ui.errors.contains { $0.contains("Eject them instead") })
        // A disk alone: nothing runs, and the caller still hears that it's over.
        for kind: FileOperationKind in [.delete, .move] {
            let result = try await controller.perform(kind, [disk], to: kind == .move ? destination : nil)
            #expect(result.isEmpty)
        }
        // Moving to a server is checked first too: an upload would delete the local copy afterwards.
        controller.run(.move, [disk], to: URL(string: "sftp://127.0.0.1:1/home/")!, window: nil)
        #expect(started == [[file]] && ui.errors.count == 4)
        #expect(s.read("USB/keep.txt") == "kept" && FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func theMountTableKnowsTheStartupDiskAndNothingElseHere() throws {
        let s = try Scratch()
        let mounts = DesktopVolumes.mountPoints()
        #expect(mounts.contains("/"))
        #expect(!mounts.contains(s.url.standardizedFileURL.path))
        #expect(DesktopVolumes.isVolume(URL(fileURLWithPath: "/"), mounts: mounts))
        #expect(!DesktopVolumes.isEjectable(URL(fileURLWithPath: "/"), mounts: mounts))
        #expect(DesktopVolumes.isVolume(s.url, mounts: [s.url.path]))
    }
}
