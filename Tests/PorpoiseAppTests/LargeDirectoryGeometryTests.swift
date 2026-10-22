import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct LargeDirectoryGeometryTests {
    init() { _ = NSApplication.shared }

    @Test func regularGeometryMatchesLegacyCellsAcrossGroupsWidthsAndZoom() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<127).map {
            FileItem(
                url: scratch.url.appendingPathComponent("\($0).txt"), name: ["Alpha", "Beta", "Gamma"][$0 % 3] + "\($0).txt", isDirectory: false)
        }
        let view = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        scroll.documentView = view
        for grouped in [false, true] {
            model.props.groupRole = grouped ? .name : nil
            for mode in [ViewMode.icons, .details, .columns] {
                model.props.mode = mode
                for width: CGFloat in [100, 401, 1000] {
                    view.layoutWidthOverride = width
                    for size: CGFloat in [16, 47.3, 128] {
                        view.previewZoom(size, commitAfter: nil)
                        let expected = legacyCells(view)
                        #expect(expected.count == view.frames.count)
                        for (actual, expected) in zip(view.frames, expected) { expectClose(actual, expected) }
                        for i in view.frames.indices {
                            let rect = view.frames[i]
                            #expect(view.candidateIndexes(in: rect.insetBy(dx: 1, dy: 1)).contains(i))
                            #expect(view.index(at: view.iconRect(i).center) == i)
                        }
                        #expect(view.groupHeaderFrames.count == model.groups.count)
                        let current = 20
                        model.currentURL = model.rows[current].item.url
                        let nextRow = expected.enumerated().filter { $0.element.minY > expected[current].minY }
                        let targetY = nextRow.first?.element.minY
                        let next =
                            nextRow.filter { $0.element.minY == targetY }.min {
                                abs($0.element.minX - expected[current].minX) < abs($1.element.minX - expected[current].minX)
                            }?.offset ?? current
                        view.keyDown(
                            with: NSEvent.keyEvent(
                                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!)
                        #expect(model.currentURL == model.rows[next].item.url)
                    }
                }
            }
        }
        model.searchResults = []
        view.computeLayout()
        #expect(view.frames.isEmpty && view.groupHeaderFrames.isEmpty)
    }

    @Test func hundredThousandCellsUseOneBandAndSnapshotsKeepTheirGeometry() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<100_000).map {
            FileItem(url: scratch.url.appendingPathComponent("\($0).txt"), name: "\($0).txt", isDirectory: false)
        }
        let view = ItemListView(model: model)
        view.layoutWidthOverride = 1000
        for mode in [ViewMode.icons, .details, .columns] {
            model.props.mode = mode
            view.previewZoom(32, commitAfter: nil)
            view.computeLayout()
            #expect(view.frames.count == 100_000)
            #expect(view.frames.bands.count == 1 && view.frames.materialized.isEmpty)
            let old = view.frames
            let last = old[99_999]
            view.previewZoom(128, commitAfter: nil)
            #expect(old[99_999] == last)
            #expect(view.frames[99_999] != last)
            let target = view.frames[99_999]
            #expect(view.candidateIndexes(in: target.insetBy(dx: 1, dy: 1)).contains(99_999))
        }
    }

    @Test func treeContinuationsSurviveWidthChangesAndInvalidateAfterCollapse() async throws {
        let scratch = try Scratch()
        try scratch.file("top/inner/deep.txt")
        try scratch.file("top/child.txt")
        try scratch.file("z.txt")
        Settings.shared.detailsExpandableFolders = true
        let model = try await DirectoryModel.loaded(scratch.url) { $0.props.mode = .details }
        model.setExpanded(scratch.path("top"), true)
        await expectEventually { model.rows.count == 4 }
        model.setExpanded(scratch.path("top/inner"), true)
        await expectEventually { model.rows.count == 5 }
        let view = ItemListView(model: model)
        view.computeLayout()
        #expect(view.treeLines == [[true], [true, true], [true, true, false], [true, false], [false]])
        let revision = view.treeLinesRevision
        for width: CGFloat in [500, 900, 1200] {
            view.layoutWidthOverride = width
            view.previewZoom(53.2, commitAfter: nil)
            #expect(view.treeLinesRevision == revision)
            #expect(view.treeLines[2] == [true, true, false])
        }
        model.setExpanded(scratch.path("top"), false)
        view.computeLayout()
        #expect(view.treeLines == [[true], [false]])
        #expect(view.treeLinesRevision != revision)
        Settings.shared.detailsExpandableFolders = false
        view.computeLayout()
        #expect(view.treeLines.isEmpty)
        Settings.shared.detailsExpandableFolders = true
        view.computeLayout()
        #expect(view.treeLines == [[true], [false]])
    }

    @Test func zoomKeepsCurrentItemAtItsScrollOffsetAndAccessibilityUsesNewFrames() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<300).map {
            FileItem(url: scratch.url.appendingPathComponent("\($0).txt"), name: "\($0).txt", isDirectory: false)
        }
        let view = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        scroll.documentView = view
        model.props.mode = .details
        view.computeLayout()
        let index = 100
        model.currentURL = model.rows[index].item.url
        view.scroll(CGPoint(x: 0, y: view.frames[index].minY - 20))
        let before = view.frames[index].minY - view.visibleRect.minY
        view.previewZoom(85, commitAfter: nil)
        #expect(abs(view.frames[index].minY - view.visibleRect.minY - before) < 1)
        let children = view.accessibilityChildren() ?? []
        #expect(!children.isEmpty)
        for case let child as ItemAccessibilityElement in children {
            #expect(child.accessibilityFrameInParentSpace() == view.frames[child.index])
        }
        #expect(view.index(at: view.iconRect(index).center) == index)
    }

    /// The previous materialized layout, retained here as an independent regression oracle.
    private func legacyCells(_ view: ItemListView) -> [CGRect] {
        guard let first = view.frames.first else { return [] }
        let h = first.height, w = first.width
        let margin = view.mode == .icons ? ItemListView.margin : view.mode == .columns ? ItemListView.columnsTop : 0
        let x = view.mode == .icons ? ItemListView.margin : view.mode == .columns ? ItemListView.columnsInset : ItemListView.sidePadding
        let headerH = view.model.groups.isEmpty ? 0 : view.lineHeight + 14
        var y = margin, col = 0, lastGroup = -2
        var result: [CGRect] = []
        for row in view.model.rows {
            if row.group != lastGroup && row.group >= 0 {
                if col != 0 { y += h; col = 0 }
                y += headerH
                lastGroup = row.group
            }
            result.append(CGRect(x: x + CGFloat(col) * w, y: y, width: w, height: h))
            col += 1
            if col == (view.mode == .icons ? view.columns : 1) { col = 0; y += h }
        }
        return result
    }

    private func expectClose(_ actual: CGRect, _ expected: CGRect) {
        #expect(abs(actual.minX - expected.minX) < 0.001 && abs(actual.minY - expected.minY) < 0.001)
        #expect(actual.size == expected.size)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
