import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Secondary windows take the app's theme: palette text and backgrounds instead of the system's, the palette's
/// accent on native controls, and colors given on purpose left alone.
@Suite(.serialized) struct ThemedWindowsTests {
    @Test @MainActor func viewsTakeThePalette() throws {
        let root = NSView()
        let label = NSTextField(labelWithString: "Label")
        let note = NSTextField(labelWithString: "Note")
        note.textColor = .secondaryLabelColor
        let custom = NSTextField(labelWithString: "Warning")
        custom.textColor = .systemRed
        let field = NSTextField(string: "value")
        let check = ClosureButton(checkboxWithTitle: "Check") { _ in }
        let push = NSButton(title: "Rebuild", target: nil, action: nil)
        let segments = NSSegmentedControl(labels: ["A", "B"], trackingMode: .selectOne, target: nil, action: nil)
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        for v in [label, note, custom, field, check, push, segments, table] as [NSView] { root.addSubview(v) }

        Theme.dress(root)

        #expect(label.textColor == Theme.windowText && note.textColor == Theme.windowTextInactive)
        #expect(custom.textColor == .systemRed)  // given on purpose
        #expect(field.textColor == Theme.viewText && field.backgroundColor?.usingColorSpace(.sRGB) == Theme.fieldBackground.usingColorSpace(.sRGB))
        let accent = try #require(Theme.accent.usingColorSpace(.sRGB))
        #expect(check.bezelColor?.usingColorSpace(.sRGB) == accent && segments.selectedSegmentBezelColor?.usingColorSpace(.sRGB) == accent)
        #expect(check.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Theme.windowText)
        #expect(push.bezelColor == nil)  // only the default button takes the accent
        #expect(!table.usesAlternatingRowBackgroundColors)
        #expect(Theme.isChoice(check) && Theme.isChoice(NSButton(radioButtonWithTitle: "R", target: nil, action: nil)) && !Theme.isChoice(push))
    }

    @Test @MainActor func onlyTheAppsSecondaryWindowsAreDressed() {
        let plain = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        Theme.dressIfThemed(plain)
        #expect(!plain.titlebarAppearsTransparent)
        let controller = DiskUtilityWindow(title: "Test", columns: [("name", "Name", 100)])
        Theme.dressIfThemed(controller.window!)
        #expect(controller.window?.titlebarAppearsTransparent == true)
    }
}
