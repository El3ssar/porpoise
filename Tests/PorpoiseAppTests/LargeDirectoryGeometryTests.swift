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

    @Test func hundredThousandCellsUseOneBandAndSnapshotsKeepTheirGeometry() async throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<100_000).map {
            FileItem(url: scratch.url.appendingPathComponent("\($0).txt"), name: "\($0).txt", isDirectory: false)
        }
        let view = ItemListView(model: model)
        view.layoutWidthOverride = 1000
        for mode in [ViewMode.icons, .details, .columns, .compact] {
            model.props.mode = mode
            view.previewZoom(32, commitAfter: nil)
            view.computeLayout()
            await expectEventually { !view.isPreparingCompact && view.frames.count == 100_000 }
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

    @Test func compactBandsMatchEveryLegacyCellAndKeepHeaderGaps() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<127).map {
            let name = ["A", "B", "C"][$0 % 3] + "\($0)." + String(repeating: "long-extension-", count: $0 % 3 + 2)
            return FileItem(url: scratch.url.appendingPathComponent(name), name: name, isDirectory: false)
        }
        model.props.mode = .compact
        let view = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        scroll.documentView = view
        for roles: [ItemRole] in [[], [.size, .modificationTime]] {
            model.props.setRoles(roles, for: .compact)
            for role: ItemRole? in [nil, .name, .extension_] {
                model.props.groupRole = role
                for height: CGFloat in [80, 301, 600] {
                    scroll.frame.size.height = height
                    for size: CGFloat in [16, 47.3, 128] {
                        view.previewZoom(size, commitAfter: nil)
                        view.computeLayout()
                        let first = try #require(view.frames.first)
                        let headerH = model.groups.isEmpty ? 0 : view.lineHeight + 14
                        let font = NSFont.systemFont(ofSize: Theme.fontSize, weight: .semibold)
                        var x = ItemListView.margin, i = 0
                        while i < model.rows.count {
                            let group = model.rows[i].group, groupX = x
                            var groupEnd = i
                            while groupEnd < model.rows.count && model.rows[groupEnd].group == group { groupEnd += 1 }
                            while i < groupEnd {
                                let end = min(groupEnd, i + view.rowsPerColumn)
                                for j in i..<end {
                                    let expected = CGRect(
                                        x: x, y: ItemListView.margin + headerH + CGFloat(j - i) * first.height,
                                        width: first.width, height: first.height)
                                    expectClose(view.frames[j], expected)
                                    #expect(view.candidateIndexes(in: expected.insetBy(dx: 1, dy: 1)).contains(j))
                                    #expect(view.index(at: view.iconRect(j).center) == j)
                                }
                                x += first.width
                                i = end
                            }
                            if group >= 0 {
                                let titleWidth = ceil((model.groups[group].title as NSString).size(withAttributes: [.font: font]).width) + 16
                                x = max(x, groupX + titleWidth)
                            }
                        }
                        #expect(view.frames.materialized.isEmpty)
                        #expect(view.frames.bands.count == max(1, model.groups.count))
                        #expect(view.frame.width == max(view.visibleWidth, x + ItemListView.margin))
                        for current in [0, 20, 126] {
                            model.currentURL = model.rows[current].item.url
                            let targetX = view.frames.dropFirst(current + 1).first { $0.minX > view.frames[current].minX }?.minX
                            let candidates = view.frames.indices.filter { view.frames[$0].minX == targetX }
                            let expected =
                                candidates.min {
                                    abs(view.frames[$0].minY - view.frames[current].minY) < abs(view.frames[$1].minY - view.frames[current].minY)
                                } ?? 126
                            view.keyDown(
                                with: NSEvent.keyEvent(
                                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!)
                            #expect(model.currentURL == model.rows[expected].item.url)
                        }
                    }
                }
            }
        }
        model.searchResults = []
        view.computeLayout()
        #expect(view.frames.isEmpty && view.frames.bands.isEmpty && view.groupHeaderFrames.isEmpty)
        #expect(view.window == nil)
    }

    @Test(arguments: [false, true])
    func cappedCompactMeasurementsExpandWhenZoomNeedsMoreText(automatic: Bool) throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        // The first value exceeds a small cap; the second is wider, and matters at a larger zoom.
        model.searchResults = ["a" + String(repeating: "w", count: 20), "z" + String(repeating: "w", count: 50)].map {
            FileItem(url: scratch.url.appendingPathComponent($0), name: $0, isDirectory: false)
        }
        model.props.mode = .compact
        Settings.shared.compactMaxWidth = automatic ? 0 : 10
        let view = ItemListView(model: model)
        view.previewZoom(16, commitAfter: nil)
        view.computeLayout()
        let small = try #require(view.compactTextMeasurement)
        #expect(!small.complete)
        if automatic { view.previewZoom(256, commitAfter: nil) } else { Settings.shared.compactMaxWidth = 45 }
        view.computeLayout()
        let large = try #require(view.compactTextMeasurement)
        #expect(large.width > small.width)
        let expected = CompactColumns.textWidth(
            widest: model.rows.map { view.textWidth(model.displayName(for: $0.item)) }.max() ?? 0,
            iconSize: view.iconSize, charWidth: view.textWidth("x"), maxChars: automatic ? 0 : 45, minimum: 5 * view.lineHeight)
        let actual = view.frames[0].width - 4 * ItemListView.pad - view.iconSize - 16
        #expect(actual == ceil(expected))
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
