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
    @Test(.isolatedSettings) @MainActor func viewsTakeThePalette() throws {
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
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
        #expect(check.image is ChoiceImage && check.alternateImage is ChoiceImage)
        #expect(segments.selectedSegmentBezelColor?.usingColorSpace(.sRGB) == accent)
        #expect(check.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Theme.windowText)
        #expect(push.bezelColor == nil)  // only the default button takes the accent
        #expect(!table.usesAlternatingRowBackgroundColors)
        #expect(Theme.isChoice(check) && Theme.isChoice(NSButton(radioButtonWithTitle: "R", target: nil, action: nil)) && !Theme.isChoice(push))
    }

    /// Checkboxes and radio buttons, header rows and Settings' tabs are drawn in the palette (macOS ignores our accent on
    /// them), and stay AppKit's controls: the same roles for VoiceOver, the same state.
    @Test(.isolatedSettings) @MainActor func systemDrawnControlsTakeThePalette() throws {
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
        let root = NSView()
        let check = NSButton(checkboxWithTitle: "Check", target: nil, action: nil)
        check.state = .on
        let radio = NSButton(radioButtonWithTitle: "Radio", target: nil, action: nil)
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Name"
        column.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        table.addTableColumn(column)
        table.headerView = NSTableHeaderView()
        for v in [check, radio, table] as [NSView] { root.addSubview(v) }

        Theme.dress(root)
        Theme.dress(root)  // again, as on a change of palette: nothing is made twice

        let checkImage = try #require(check.image as? ChoiceImage)
        Theme.dress(root)
        #expect(check.image === checkImage && radio.image is ChoiceImage && radio.alternateImage is ChoiceImage)
        #expect(check.cell?.accessibilityRole() == .checkBox && radio.cell?.accessibilityRole() == .radioButton && check.state == .on)
        #expect(table.headerView is ThemedHeaderView && column.headerCell is ThemedHeaderCell && column.headerCell.stringValue == "Name")

        // Each box draws, off and on, in the palette.
        for radio in [false, true] {
            for on in [false, true] {
                let cg = try #require(ChoiceImage(radio: radio, on: on).cgImage(forProposedRect: nil, context: nil, hints: nil))
                let rep = NSBitmapImageRep(cgImage: cg)
                let middle = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                #expect(middle.alphaComponent > 0.9)
            }
        }

        // A pop-up keeps its menu, selection and handler when it starts drawing in the palette.
        var chosen = -1
        let popUp = ClosurePopup { chosen = $0.indexOfSelectedItem }
        popUp.addItems(withTitles: ["A", "B", "C"])
        popUp.selectItem(at: 2)
        root.addSubview(popUp)
        Theme.dress(root)
        Theme.dress(root)
        #expect(popUp.cell is ThemedPopUpButtonCell && popUp.numberOfItems == 3 && popUp.indexOfSelectedItem == 2)
        popUp.selectItem(at: 1)
        popUp.sendAction(popUp.action, to: popUp.target)
        #expect(chosen == 1 && popUp.cell?.accessibilityRole() == .popUpButton)

        let tabs = ThemedTabViewController()
        tabs.tabStyle = .toolbar
        for (title, symbol) in [("One", "folder"), ("Two", "keyboard")] {
            let item = NSTabViewItem(viewController: NSViewController())
            item.viewController?.view = NSView()
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.isReleasedWhenClosed = false
        let buttons = tabs.tabButtons
        #expect(buttons.map(\.title) == ["One", "Two"])
        #expect(buttons.map(\.isSelected) == [true, false])
        #expect(buttons.allSatisfy { $0.accessibilityRole() == .radioButton && $0.accessibilityLabel() == $0.title })
        buttons[1].performClick(nil)  // as a click, the keyboard or the » menu does
        #expect(tabs.selectedTabViewItemIndex == 1 && buttons.map(\.isSelected) == [false, true])
        #expect(buttons[1].accessibilityValue() as? Int == 1)
        #expect(window.toolbar?.items.allSatisfy { $0.menuFormRepresentation?.title == $0.label } == true)
        window.close()
    }

    /// The native theme (the default) leaves AppKit's controls as macOS draws them, and gives back those a palette theme
    /// had replaced when the user switches back: checkboxes, radio buttons, pop-ups, header rows, the accent, tables'
    /// alternating rows.
    @Test(.isolatedSettings) @MainActor func theNativeThemeKeepsAppKitsControls() throws {
        let root = NSView()
        let check = NSButton(checkboxWithTitle: "Check", target: nil, action: nil)
        let radio = NSButton(radioButtonWithTitle: "Radio", target: nil, action: nil)
        let label = NSTextField(labelWithString: "Label")
        let push = NSButton(title: "OK", target: nil, action: nil)
        push.keyEquivalent = "\r"
        let segments = NSSegmentedControl(labels: ["A", "B"], trackingMode: .selectOne, target: nil, action: nil)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: ["A", "B"])
        popUp.selectItem(at: 1)
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Name"
        table.addTableColumn(column)
        table.headerView = NSTableHeaderView()
        for v in [check, radio, label, push, segments, popUp, table] as [NSView] { root.addSubview(v) }

        #expect(Tokens.isNative)
        Theme.dress(root)
        let checkImage = check.image, radioImage = radio.image
        func expectAppKits(_ sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(!(check.image is ChoiceImage) && check.image === checkImage && radio.image === radioImage, sourceLocation: sourceLocation)
            #expect(!(popUp.cell is ThemedPopUpButtonCell), sourceLocation: sourceLocation)
            #expect(!(table.headerView is ThemedHeaderView) && !(column.headerCell is ThemedHeaderCell), sourceLocation: sourceLocation)
            #expect(table.usesAlternatingRowBackgroundColors, sourceLocation: sourceLocation)
            #expect(push.bezelColor == nil && segments.selectedSegmentBezelColor == nil, sourceLocation: sourceLocation)
            #expect(label.textColor == .labelColor, sourceLocation: sourceLocation)
            let title = check.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            #expect(title == nil || Theme.isSystem(title, Theme.primaryText), sourceLocation: sourceLocation)
        }
        expectAppKits()

        // Breeze dresses them; back to the native theme, they are AppKit's again, with their state and roles.
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
        Theme.dress(root)
        #expect(check.image is ChoiceImage && popUp.cell is ThemedPopUpButtonCell && table.headerView is ThemedHeaderView)
        #expect(push.bezelColor != nil && !table.usesAlternatingRowBackgroundColors && label.textColor == Theme.windowText)
        Theme.dress(root)  // a second change of palette records nothing new
        check.title = "Renamed"  // changed while the palette is on: the native theme keeps the new title
        Settings.shared.updateAppearance { $0.themeName = AppearanceTheme.systemName }
        Theme.dress(root)
        expectAppKits()
        #expect(check.title == "Renamed")
        #expect(popUp.numberOfItems == 2 && popUp.indexOfSelectedItem == 1 && popUp.cell?.accessibilityRole() == .popUpButton)
        #expect(radio.cell?.accessibilityRole() == .radioButton && column.headerCell.stringValue == "Name")
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
