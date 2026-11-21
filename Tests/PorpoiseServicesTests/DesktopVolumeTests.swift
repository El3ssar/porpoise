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
        let disks = [FileItem(url: URL(fileURLWithPath: "/Volumes/Zed"), name: "Zed", isDirectory: true), FileItem(url: root, name: "Mac", isDirectory: true)]
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
        let file = try s.file("keep moving.txt"), destination = try s.folder("Destination")
        let ui = ScriptedUI(), controller = makeController(ui)
        var started: [[URL]] = []
        ui.onJobStarted = { started.append($0.sources) }
        let moved = try await controller.perform(.move, [root, file], to: destination)
        #expect(moved.map(\.lastPathComponent) == ["keep moving.txt"])
        #expect(started == [[file]])
        #expect(ui.errors.contains { $0.contains("Eject them instead") })
        for kind: FileOperationKind in [.trash, .delete, .move] {
            controller.run(kind, [root], to: kind == .move ? destination : nil, window: nil)
        }
        #expect(started == [[file]] && ui.errors.count == 4)
        // Copying a disk's contents is allowed, as in Finder; only its own top level is protected here.
        #expect(!DesktopVolumes.isVolume(destination))
    }
}
