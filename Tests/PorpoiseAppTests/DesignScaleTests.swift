import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import Testing

@testable import Porpoise

/// The design scale (`Tokens`) and the forms and panels that follow it.
@Suite(.serialized, .isolatedSettings) @MainActor struct DesignScaleTests {
    init() { _ = NSApplication.shared }

    @Test func theTypeAndRadiusScaleIsMacOSs() {
        typealias F = Tokens.FontSize
        #expect([F.caption, F.small, F.callout, F.body, F.title3, F.title2, F.title, F.largeTitle] == [10, 11, 12, 13, 15, 17, 22, 26])
        typealias R = Tokens.Radius
        #expect([R.small, R.row, R.card, R.sheet] == [4, 6, 10, 14])
    }

    @Test func formButtonsSitInTheControlColumnSideBySide() throws {
        let form = FormBuilder()
        let field = form.text("Home location:", "/Users/me") { _ in }
        form.button("Use Current Location") {}
        form.button("Use Default Location") {}
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = form.view
        form.view.layoutSubtreeIfNeeded()
        func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
        let found = buttons(form.view).filter { $0.title.hasPrefix("Use ") }
        #expect(found.count == 2)
        let frames = found.map { $0.convert($0.bounds, to: nil) }
        let fieldFrame = field.convert(field.bounds, to: nil)
        // One row, starting where the field starts.
        #expect(abs(frames[0].midY - frames[1].midY) < 1)
        #expect(abs(frames[0].minX - fieldFrame.minX) <= 2, "\(frames[0].minX) vs \(fieldFrame.minX)")
    }
}
