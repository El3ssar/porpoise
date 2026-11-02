import AVKit
import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Geometry and asynchronous preview transitions only: these fixtures never create or present a window.
@MainActor @Suite(.serialized, .isolatedSettings) struct InformationPanelLayoutTests {
    init() { _ = NSApplication.shared }

    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }

    private func detailsScroll(_ panel: InformationPanel) throws -> NSScrollView {
        try #require(panel.subviews.compactMap { $0 as? NSScrollView }.first)
    }

    private func selected(_ file: URL, in pane: ViewContainer, panel: InformationPanel) {
        pane.list.select(file)
        panel.show(hovered: nil, container: pane)
    }

    @Test func textFillsThePreviewAreaAndDetailsFitTheLegacyScrollbarViewport() async throws {
        Settings.shared.infoShowPreview = true
        let scratch = try Scratch()
        let file = try scratch.file(String(repeating: "long-name-", count: 15) + ".swift", "let value = 42\n")
        let pane = ViewContainer(url: scratch.url)
        try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == 1 })
        let panel = InformationPanel(frame: CGRect(x: 0, y: 0, width: 280, height: 600))
        selected(file, in: pane, panel: panel)
        try #require(await eventually { panel.codePreview.document != nil })
        let scroll = try detailsScroll(panel)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        for height in [600.0, 180] {
            panel.frame.size.height = height
            panel.needsLayout = true
            panel.layoutSubtreeIfNeeded()
            let document = try #require(scroll.documentView)
            #expect(scroll.contentSize.width < scroll.bounds.width)
            #expect(abs(document.frame.width - scroll.contentSize.width) <= 0.5)
            for child in document.subviews {
                #expect(child.frame.minX >= 0 && child.frame.maxX <= scroll.contentSize.width + 0.5)
            }
            #expect(panel.codePreview.frame.width == panel.bounds.width - 24)
            #expect(panel.codePreview.frame.maxY <= scroll.frame.minY - 12)
            #expect(scroll.frame.maxY <= panel.bounds.height - 16 + 0.5)
            if height == 600 { #expect(panel.codePreview.frame.height > 240) }
        }
    }

    @Test func detailsScrollResetsForANewSelectionAndNotForTheSameItem() async throws {
        let scratch = try Scratch()
        let first = try scratch.file(String(repeating: "first-", count: 25) + ".txt", "one")
        let second = try scratch.file("second.txt", "two")
        let pane = ViewContainer(url: scratch.url)
        try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == 2 })
        let panel = InformationPanel(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        selected(first, in: pane, panel: panel)
        try #require(await eventually { descendants(panel, as: NSTextField.self).contains { $0.stringValue.hasPrefix("Read") } })
        panel.layoutSubtreeIfNeeded()
        let scroll = try detailsScroll(panel)
        let document = try #require(scroll.documentView)
        try #require(document.frame.height > scroll.contentSize.height + 20)
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: 20))
        scroll.reflectScrolledClipView(clip)
        let offset = clip.bounds.minY
        try #require(offset > 0)
        panel.refresh()
        #expect(clip.bounds.minY == offset)
        selected(second, in: pane, panel: panel)
        #expect(clip.bounds.minY == 0)
        try #require(await eventually { descendants(panel, as: NSTextField.self).contains { $0.stringValue == "second.txt" } })
    }

    @Test func binaryFallbackAndTheNextTextSelectionRestoreTheColumnWidth() async throws {
        Settings.shared.infoShowPreview = true
        let scratch = try Scratch()
        let text = try scratch.file("readable.swift", "let readable = true")
        let binary = try scratch.file("binary.swift")
        try Data([0, 1, 2, 3]).write(to: binary)
        let pane = ViewContainer(url: scratch.url)
        try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == 2 })
        let column = ColumnPreviewView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        pane.list.select(text)
        column.show(text, container: pane)
        try #require(await eventually { column.information.codePreview.document != nil && !column.information.codePreview.isLoading })
        column.layoutSubtreeIfNeeded()
        #expect(column.information.frame.width == column.bounds.width)
        pane.list.select(binary)
        column.show(binary, container: pane)
        try #require(await eventually { column.information.codePreview.isHidden && !column.information.codePreview.isLoading })
        column.layoutSubtreeIfNeeded()
        #expect(column.information.frame.width == ColumnPreviewView.contentWidth)
        #expect(abs(column.information.frame.midX - column.bounds.midX) <= 0.5)
        pane.list.select(text)
        column.show(text, container: pane)
        try #require(await eventually { column.information.codePreview.document != nil && !column.information.codePreview.isLoading })
        column.layoutSubtreeIfNeeded()
        #expect(column.information.frame.width == column.bounds.width)
        column.frame.size.width = 360
        column.layoutSubtreeIfNeeded()
        #expect(column.information.frame.width == 360)
    }

    @Test func shortMediaKeepsFullWidthControlsAboveTheDetailsFooter() async throws {
        Settings.shared.infoShowPreview = true
        let scratch = try Scratch()
        let file = try scratch.file("selected.txt", "details")
        let pane = ViewContainer(url: scratch.url)
        try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == 1 })
        let panel = InformationPanel(frame: CGRect(x: 0, y: 0, width: 280, height: 200))
        selected(file, in: pane, panel: panel)
        try #require(await eventually { descendants(panel, as: NSTextField.self).contains { $0.stringValue.hasPrefix("Read") } })
        let playerView = try #require(descendants(panel, as: AVPlayerView.self).first)
        let controls = try #require(descendants(panel, as: MediaControls.self).first)
        let player = AVPlayer()
        playerView.player = player
        controls.attach(player, duration: 120)
        defer { controls.detach(); playerView.player = nil }
        panel.layoutSubtreeIfNeeded()
        controls.layoutSubtreeIfNeeded()
        let scroll = try detailsScroll(panel)
        #expect(!controls.isHidden && controls.frame.width == panel.bounds.width - 24)
        #expect(controls.frame.maxY <= scroll.frame.minY - 12)
        #expect(controls.subviews.filter { !$0.isHidden }.allSatisfy { controls.bounds.contains($0.frame) })
    }
}
