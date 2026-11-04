import AppKit
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Construct and lay out alerts without presenting, ordering or activating their windows.
@MainActor @Suite(.serialized, .isolatedSettings) struct OperationErrorDialogTests {
    init() { _ = NSApplication.shared }

    private func recoveryMessage(paths: Int) -> String {
        "The operation could not be fully restored: Permission denied.\nReview these locations before retrying:\n"
            + (0..<paths).map { "/Volumes/Fixture/Research/Experiment-\($0)/日本語-results-and-documents.txt" }.joined(separator: "\n")
    }

    private func details(_ alert: NSAlert) throws -> (NSScrollView, NSTextView) {
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        return (scroll, try #require(scroll.documentView as? NSTextView))
    }

    private func expectBoundedAndUnshown(_ alert: NSAlert) {
        alert.layout()
        #expect(alert.window.frame.width <= 640 && alert.window.frame.height <= 600)
        #expect(!alert.window.isVisible && !alert.window.isKeyWindow)
    }

    @Test func shortSingleErrorsKeepTheirOriginalPresentation() {
        let message = "You don’t have permission to change this file."
        let alert = FileOperationsDialogs.errorAlert([message])
        defer { alert.window.close() }
        #expect(alert.alertStyle == .warning)
        #expect(alert.messageText == message && alert.informativeText.isEmpty && alert.accessoryView == nil)
        expectBoundedAndUnshown(alert)
    }

    @Test(arguments: [1, 100, 10_000]) func recoveryPathsRemainCopyableInsideABoundedAlert(count: Int) throws {
        let message = recoveryMessage(paths: count)
        let alert = FileOperationsDialogs.errorAlert([message])
        defer { alert.window.close() }
        let (scroll, text) = try details(alert)
        #expect(text.string == message, "The cause and every original path must remain available")
        #expect(text.isSelectable && !text.isEditable && !text.isRichText)
        #expect(text.accessibilityLabel() == "Operation error details")
        #expect(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        #expect(!text.isHorizontallyResizable && text.textContainer?.widthTracksTextView == true)
        #expect(text.textContainer?.lineBreakMode == .byCharWrapping, "Unbroken paths must wrap within the details viewport")
        #expect(text.layoutManager?.allowsNonContiguousLayout == true)
        expectBoundedAndUnshown(alert)
    }

    @Test func longSingleLinesAndAllErrorsRemainAvailableWithoutTruncation() throws {
        let messages =
            [String(repeating: "日本語-very-long-unbroken-path/", count: 80)]
            + (0..<20).map { "Error \($0): /Volumes/Fixture/file-\($0).txt" }
        for errors in [[messages[0]], messages] {
            let alert = FileOperationsDialogs.errorAlert(errors)
            defer { alert.window.close() }
            let (_, text) = try details(alert)
            #expect(text.string == errors.joined(separator: "\n\n"))
            #expect(text.string.hasSuffix(errors.last ?? ""), "Later errors must not disappear after the first eight")
            expectBoundedAndUnshown(alert)
        }
    }

    @Test func optionalLightAndDarkCapturesStayOffscreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["PORPOISE_OPERATION_ERROR_CAPTURES"] else { return }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try #require(NSAppearance(named: look))
            NSApp.appearance = appearance
            let alert = FileOperationsDialogs.errorAlert([recoveryMessage(paths: 100)])
            defer { alert.window.close() }
            alert.window.appearance = appearance
            expectBoundedAndUnshown(alert)
            let content = try #require(alert.window.contentView)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            appearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("operation-errors-\(name).png"))
            #expect(!alert.window.isVisible && !alert.window.isKeyWindow)
        }
    }
}
