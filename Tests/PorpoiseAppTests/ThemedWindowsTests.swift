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

    /// Secondary windows are themed by being one: those a hand-kept list missed (Create From Template) are dressed too,
    /// so is a panel no controller owns, and a window opts out instead of in.
    @Test @MainActor func secondaryWindowsAreThemedUnlessTheyOptOut() {
        let template = TemplateWindow(folder: FileManager.default.temporaryDirectory) { _ in }
        Theme.dressIfThemed(template.window!)
        #expect(template.window?.titlebarAppearsTransparent == true)
        let panel = SecondaryPanel(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        Theme.dressIfThemed(panel)
        #expect(panel.titlebarAppearsTransparent)

        final class OwnLook: SecondaryWindowController { override var isThemed: Bool { false } }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let own = OwnLook(window: window)
        Theme.dressIfThemed(own.window!)
        #expect(own.window?.titlebarAppearsTransparent == false)
    }

    /// A presented window keeps its controller until it closes; its content stack fills it inside the margins.
    @Test @MainActor func secondaryWindowsStayOpenUntilClosedAndStackTheirContent() throws {
        weak var kept: SecondaryWindowController?
        do {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let controller = SecondaryWindowController(window: window)
            let stack = controller.contentStack(insets: NSEdgeInsets(top: 10, left: 12, bottom: 14, right: 16))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(stack.frame == CGRect(x: 12, y: 14, width: 300 - 28, height: 200 - 24))
            controller.keepOpen(); controller.keepOpen()
            #expect(SecondaryWindowController.openWindows().filter { $0 === controller }.count == 1)
            kept = controller
        }
        let controller = try #require(kept)  // only the registry holds it
        controller.window?.close()
        #expect(!SecondaryWindowController.openWindows().contains { $0 === controller })
    }
}
