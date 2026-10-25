import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// UI-5 (DESIGN-CONTRACT §3, S2/S3, D1): dialogs sit on the 20-pt window margin, and a sheet's button row is
/// right-aligned with the default button rightmost, 24 pt under the content.
@Suite(.serialized) @MainActor struct DialogMetricsTests {
    init() { _ = NSApplication.shared }

    private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }

    /// The content stack's edges against the window's content view.
    private func margins(_ window: NSWindow) throws -> NSEdgeInsets {
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let stack = try #require(content.subviews.first { $0 is NSStackView })
        let f = stack.frame
        return NSEdgeInsets(
            top: content.bounds.height - f.maxY, left: f.minX, bottom: f.minY, right: content.bounds.width - f.maxX)
    }

    @Test func dialogsSitOnTheWindowMargin() throws {
        let scratch = try Scratch()
        let template = TemplateWindow(folder: scratch.url) { _ in }
        let rename = BatchRenameDialog([try scratch.file("a.txt"), try scratch.file("b.txt")]) { _ in }
        let store = DiagnosticStore()
        let diagnostics = DiagnosticsExportWindowController(export: try store.preview())
        defer { [template.window, rename.window, diagnostics.window].forEach { $0?.close() } }
        for (name, controller) in [("template", template), ("rename", rename), ("diagnostics", diagnostics)] as [(String, NSWindowController)] {
            let m = try margins(try #require(controller.window))
            for (edge, value) in [("top", m.top), ("left", m.left), ("bottom", m.bottom), ("right", m.right)] {
                #expect(abs(value - Tokens.Space.xl) < 0.5, "\(name) \(edge) margin \(value)")
            }
        }
    }

    @Test func sheetButtonsAreRightAlignedWithTheDefaultLast() throws {
        let scratch = try Scratch()
        let template = TemplateWindow(folder: scratch.url) { _ in }
        let rename = BatchRenameDialog([try scratch.file("a.txt"), try scratch.file("b.txt")]) { _ in }
        defer { [template.window, rename.window].forEach { $0?.close() } }
        for controller in [template, rename] as [NSWindowController] {
            let content = try #require(controller.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let defaultButton = try #require(Self.views(in: content).compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\r" })
            let row = try #require(defaultButton.superview as? NSStackView)
            #expect(row.arrangedSubviews.last === defaultButton)
            let frame = defaultButton.convert(defaultButton.alignmentRect(forFrame: defaultButton.bounds), to: content)
            #expect(abs(content.bounds.width - frame.maxX - Tokens.Space.xl) < 1, "\(controller): right edge \(frame.maxX)")
            let stack = try #require(row.superview as? NSStackView)
            let above = try #require(stack.arrangedSubviews.firstIndex(of: row).map { stack.arrangedSubviews[$0 - 1] })
            #expect(stack.customSpacing(after: above) == Tokens.Space.xxl)
        }
    }
}
