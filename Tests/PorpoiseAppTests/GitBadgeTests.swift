import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Real models, AppKit drawing and VoiceOver for every view mode, including the shared Column row renderer.
@Suite(.serialized, .isolatedSettings) @MainActor struct GitBadgeTests {
    init() {
        _ = NSApplication.shared
        #if DEBUG
        FocusGuard.install()
        #endif
    }
    private func picture(_ list: ItemListView, row: Int) -> CGImage? {
        var image: CGImage?
        list.effectiveAppearance.performAsCurrentDrawingAppearance { image = list.picture(ofRow: row) }
        return image
    }
    @Test func everyViewDrawsBadgesAndExposesTheirMeaning() async throws {
        let f = try await Task.detached {
            let f = try LocalGitFixture()
            try f.scratch.file("rename.txt", "rename"); try f.scratch.file("conflict.txt", "base");
            try f.scratch.file("modified.txt", "before"); try f.scratch.file(".gitignore", "ignored/\n")
            try f.record(); try f.scratch.file("modified.txt", "after")
            try f.git(["mv", "rename.txt", "renamed.txt"])
            try f.scratch.file("added.txt", "added"); try f.git(["add", "added.txt"])
            try f.scratch.file("untracked.txt", "untracked")
            let hash = String(decoding: try f.git(["hash-object", "-w", "--stdin"], stdin: Data("conflict".utf8)), as: UTF8.self).trimmingCharacters(
                in: .newlines)
            try f.git(
                ["update-index", "--index-info"],
                stdin: Data(
                    ("0 " + String(repeating: "0", count: 40) + "\tconflict.txt\n"
                        + "100644 \(hash) 1\tconflict.txt\n100644 \(hash) 2\tconflict.txt\n100644 \(hash) 3\tconflict.txt\n").utf8))
            try f.scratch.file("new/deep/file", "new"); try f.scratch.file("ignored/file", "ignored")
            return f
        }.value
        let pane = ViewContainer(url: f.url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane
        defer { window.close() }
        try #require(await eventually { !pane.model.isLoading && pane.model.gitStatus != nil })
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for mode in [ViewMode.details, .icons, .compact, .columns] {
                pane.setMode(mode); pane.layoutSubtreeIfNeeded(); pane.list.computeLayout()
                let index = try #require(pane.model.index(of: f.scratch.path("modified.txt")))
                let item = pane.model.rows[index].item
                #expect(pane.list.gitBadge(item) == .modified)
                for (name, kind) in [
                    ("added.txt", GitFileStatus.added), ("untracked.txt", .untracked), ("conflict.txt", .conflicted), ("renamed.txt", .renamed),
                ] {
                    let row = try #require(pane.model.index(of: f.scratch.path(name)))
                    #expect(pane.list.gitBadge(pane.model.rows[row].item) == kind)
                    #expect((ItemAccessibilityElement(list: pane.list, index: row).accessibilityValue() as? String)?.contains(kind.label) == true)
                    #expect(picture(pane.list, row: row) != nil)
                }
                let modified = try #require(picture(pane.list, row: index))
                #expect(modified.width > 0 && modified.height > 0)
                let accessible = ItemAccessibilityElement(list: pane.list, index: index)
                #expect((accessible.accessibilityValue() as? String)?.contains("Git: modified") == true)
                #expect(pane.model.gitStatus?.snapshot.status(for: "new", directory: true) == .changedFolder)
                let ignored = try #require(pane.model.rows.first { $0.item.name == "ignored" }?.item)
                #expect(pane.list.gitBadge(ignored) == .ignored)
                #expect(pane.statusBar.displayText.contains("⎇ main"))
                if let output = ProcessInfo.processInfo.environment["PORPOISE_GIT_CAPTURES"] {
                    let image = NSBitmapImageRep(cgImage: modified)
                    if let full = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) {
                        pane.cacheDisplay(in: pane.bounds, to: full)
                        try full.representation(using: .png, properties: [:])?.write(
                            to: URL(fileURLWithPath: output).appendingPathComponent("pane-\(mode.rawValue)-\(appearance.rawValue).png"))
                    }
                    try image.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: output).appendingPathComponent("\(mode.rawValue)-\(appearance.rawValue).png"))
                }
                Settings.shared.showGitStatus = false
                pane.list.computeLayout()
                #expect(pane.model.gitStatus == nil)
                #expect(!pane.statusBar.displayText.contains("⎇"))
                let clean = try #require(picture(pane.list, row: index))
                #expect(modified.dataProvider?.data as Data? != clean.dataProvider?.data as Data?)
                Settings.shared.showGitStatus = true
                try #require(await eventually { pane.model.gitStatus != nil })
            }
        }
    }
    @Test func contextMenuShowsChangesOnlyForLocalChangedFiles() async throws {
        let f = try await Task.detached {
            let f = try LocalGitFixture(); try f.scratch.file("file.txt", "before"); try f.record()
            try f.scratch.file("file.txt", "after"); return f
        }.value
        let controller = MainWindowController(urls: [f.url])
        defer { controller.window?.close() }
        let pane = controller.view
        try #require(await eventually { !pane.model.isLoading && pane.model.gitStatus != nil })
        let item = try #require(pane.model.items.first { $0.name == "file.txt" })
        pane.model.selection = [item.url]
        let action = try #require(controller.contextMenu(for: item, in: pane).items.first { $0.title == "Show Changes" })
        controller.showGitChanges(action)
        try #require(await eventually { FileDiffWindow.current != nil })
        let comparison = try #require(FileDiffWindow.current)
        defer { comparison.window?.close() }
        func textFields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
        }
        try #require(
            await eventually {
                comparison.window?.contentView.map { textFields($0).contains { $0.stringValue.contains("Read-only Git comparison") } } == true
            })
        #expect(comparison.leftURL.lastPathComponent == "HEAD-file.txt")
        #expect(comparison.window?.title.hasPrefix("Compare Files") == true)
        #expect(!comparison.validateMenuItem(NSMenuItem(title: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "")))
        Settings.shared.showGitStatus = false
        #expect(!controller.contextMenu(for: item, in: pane).items.contains { $0.title == "Show Changes" })
    }
}
