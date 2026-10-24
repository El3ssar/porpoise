import AppKit

/// The parts of native controls macOS draws in its own accent whatever we ask (`bezelColor` is ignored on checkboxes and
/// radio buttons in our windows), drawn in the palette instead: the controls stay AppKit's, so focus, the keyboard and
/// VoiceOver work as they did.
extension Theme {
    /// Marks drawn on the accent (a check, a radio's dot, a pop-up's arrows): white, or near black on a light accent.
    static let onAccent = derived {
        guard let c = accent.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
    }

    /// Gives a checkbox or radio button the palette's box (once: the box follows the palette by itself).
    static func dressChoice(_ button: NSButton) {
        guard !(button.image is ChoiceImage) else { return }
        choiceImages.setObject(ChoiceOriginal(button.image, button.alternateImage), forKey: button)
        let radio = button.cell?.accessibilityRole() == .radioButton
        button.image = ChoiceImage(radio: radio, on: false)
        button.alternateImage = ChoiceImage(radio: radio, on: true)
        // A button with its own image tells VoiceOver it is a checkbox: a radio button says what it still is.
        if radio { button.cell?.setAccessibilityRole(.radioButton) }
    }

    /// Gives a table the palette's header row (once: it follows the palette by itself).
    static func dressHeader(_ table: NSTableView) {
        guard let header = table.headerView, !(header is ThemedHeaderView) else { return }
        let themedHeader = ThemedHeaderView(frame: header.frame)
        table.headerView = themedHeader
        for column in table.tableColumns where !(column.headerCell is ThemedHeaderCell) {
            let old = column.headerCell
            let cell = ThemedHeaderCell(textCell: old.stringValue)
            cell.alignment = old.alignment
            cell.font = old.font
            cell.lineBreakMode = old.lineBreakMode
            column.headerCell = cell
        }
    }

    /// A checkbox or radio button drawn by AppKit again (the native theme), with the images AppKit gave it.
    static func undressChoice(_ button: NSButton) {
        guard button.image is ChoiceImage else { return }
        let original = choiceImages.object(forKey: button)
        button.image = original?.image
        button.alternateImage = original?.alternate
        choiceImages.removeObject(forKey: button)
    }

    private final class ChoiceOriginal {
        let image: NSImage?, alternate: NSImage?
        init(_ image: NSImage?, _ alternate: NSImage?) { (self.image, self.alternate) = (image, alternate) }
    }

    /// Each dressed checkbox's and radio button's own images, to give back in the native theme.
    private static let choiceImages = NSMapTable<NSButton, ChoiceOriginal>.weakToStrongObjects()

    /// A table's header row drawn by AppKit again (the native theme).
    static func undressHeader(_ table: NSTableView) {
        guard let header = table.headerView as? ThemedHeaderView else { return }
        table.headerView = NSTableHeaderView(frame: header.frame)
        for column in table.tableColumns where column.headerCell is ThemedHeaderCell {
            let old = column.headerCell
            let cell = NSTableHeaderCell(textCell: old.stringValue)
            cell.alignment = old.alignment
            cell.font = old.font
            cell.lineBreakMode = old.lineBreakMode
            column.headerCell = cell
        }
    }
}

/// A checkbox's or radio button's box in the palette, as Breeze draws it: a frame in the text color over the view color
/// when off, filled with the accent and marked in the selection text color when on. Drawn when shown, so it is always in
/// the palette and look of the moment.
final class ChoiceImage: NSImage {
    static let side: CGFloat = 14
    static let margin: CGFloat = 3

    convenience init(radio: Bool, on: Bool) {
        // As wide as the system's box with its margin, so the title keeps its distance.
        self.init(size: NSSize(width: Self.side + Self.margin, height: Self.side), flipped: false) { rect in
            ChoiceImage.draw(in: NSRect(x: rect.minX, y: rect.minY, width: Self.side, height: Self.side), radio: radio, on: on)
            return true
        }
        cacheMode = .never
        accessibilityDescription = nil
    }

    static func draw(in rect: NSRect, radio: Bool, on: Bool) {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = radio ? NSBezierPath(ovalIn: box) : NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)  // Breeze's box corner (measured)
        path.lineWidth = 1
        if on {
            Theme.accent.setFill()
            path.fill()
            Theme.accent.mixed(with: Theme.windowText, 0.2).setStroke()
            path.stroke()
            Theme.onAccent.set()
            if radio {
                let dot = rect.insetBy(dx: rect.width * 0.32, dy: rect.height * 0.32)
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.52))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.30))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.72))
                mark.lineWidth = 1.8
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                mark.stroke()
            }
        } else {
            Theme.fieldBackground.setFill()
            path.fill()
            Theme.windowText.mixed(with: Theme.windowBackground, 0.55).setStroke()
            path.stroke()
        }
    }
}

/// A table's header row in the palette: the window color, the text color, the frame color between columns and below.
final class ThemedHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        Theme.frame.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: bounds.width, height: 1).fill()
    }
}

/// A column title in the header row: the palette's text on the window color, with the sort arrow when the table is sorted
/// by its column.
final class ThemedHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.windowBackground.setFill()
        cellFrame.fill()
        Theme.frame.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 4, width: 1, height: cellFrame.height - 8).fill()
        let sort = sortState(in: controlView, at: cellFrame)
        var titleFrame = cellFrame.insetBy(dx: 4, dy: 0)
        if sort != nil { titleFrame.size.width -= 12 }
        let title = NSMutableAttributedString(attributedString: attributedStringValue)
        title.addAttribute(.foregroundColor, value: Theme.windowText, range: NSRange(location: 0, length: title.length))
        let size = title.size()
        titleFrame.origin.y += (titleFrame.height - size.height) / 2
        titleFrame.size.height = size.height
        title.draw(with: titleFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let ascending = sort { drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0) }
    }

    /// Whether the table is sorted by this cell's column, ascending, or nil when it isn't.
    private func sortState(in controlView: NSView, at frame: NSRect) -> Bool? {
        guard let header = controlView as? NSTableHeaderView, let table = header.tableView,
            let first = table.sortDescriptors.first
        else { return nil }
        let index = header.column(at: NSPoint(x: frame.midX, y: frame.midY))
        guard index >= 0, table.tableColumns[index].sortDescriptorPrototype?.key == first.key else { return nil }
        return first.ascending
    }
}

/// Settings' pages as toolbar tabs drawn in the theme's colours (the system's in the native theme): the selected one
/// with its symbol in the accent on a pressed background. Each tab is a button: it takes the keyboard focus, and
/// VoiceOver reads it as a radio button among the tabs, selected or not. They stay buttons in every theme: the theme
/// changes while Settings is open, and a toolbar item can't give up its view again (AppKit traps on nil), nor can the
/// tab view controller's items be swapped under it.
final class ThemedTabViewController: NSTabViewController {
    private var buttons: [NSToolbarItem.Identifier: TabButton] = [:]

    // The buttons show their own title. Set once the window (and its toolbar) is there: not yet in viewDidLoad.
    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.toolbar?.displayMode = .iconOnly
    }

    override func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // The tab view controller's own item (it removes exactly those when it goes), showing our button.
        guard let item = super.toolbar(toolbar, itemForItemIdentifier: itemIdentifier, willBeInsertedIntoToolbar: flag),
            let index = tabViewItems.firstIndex(where: { $0.label == item.label })
        else { return nil }
        let button = TabButton(title: item.label, symbol: tabViewItems[index].image) { [weak self] in
            self?.selectedTabViewItemIndex = index
        }
        button.isSelected = index == selectedTabViewItemIndex
        buttons[itemIdentifier] = button
        item.view = button
        // In the » menu when the window is too narrow for every tab.
        let menuItem = NSMenuItem(title: item.label, action: #selector(TabButton.performClick(_:)), keyEquivalent: "")
        menuItem.target = button
        item.menuFormRepresentation = menuItem
        return item
    }

    override func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    /// Called when the user (or code) shows another page.
    var onSelect: ((NSTabViewItem) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        tintTabs()
        if let tabViewItem { onSelect?(tabViewItem) }
    }

    /// Marks the selected tab and draws every tab again, in the palette (also when the palette or the look changes,
    /// from `Theme.dress`).
    func tintTabs() {
        let selected = tabView.selectedTabViewItem?.label
        for button in buttons.values {
            button.isSelected = button.title == selected
            button.needsDisplay = true
        }
    }

    /// The tabs' buttons, in order (for tests).
    var tabButtons: [TabButton] {
        tabViewItems.compactMap { item in buttons.values.first { $0.title == item.label } }
    }
}

/// One of Settings' tabs: its symbol over its title, in the palette.
final class TabButton: NSButton {
    private let handler: () -> Void
    private let symbol: NSImage?
    var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected ? 1 : 0)
            needsDisplay = true
        }
    }

    init(title: String, symbol: NSImage?, _ handler: @escaping () -> Void) {
        self.handler = handler
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 50))
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
        setAccessibilityRole(.radioButton)
        setAccessibilityRoleDescription("tab")
        setAccessibilityLabel(title)
        setAccessibilityValue(0)
        let width = ceil((title as NSString).size(withAttributes: [.font: Self.titleFont]).width) + 10
        widthAnchor.constraint(equalToConstant: max(44, width)).isActive = true
        heightAnchor.constraint(equalToConstant: 50).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private static var titleFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize + 1) }

    @objc private func fire() { handler() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 50) }

    override func draw(_ dirtyRect: NSRect) {
        // The selected tab's symbol takes the accent; its title stays in the text colour, which reads in every palette
        // (accent-coloured text falls below 4.5:1 in several).
        let color = isSelected ? Theme.accent : Theme.windowText
        if isSelected || isHighlighted {
            (isHighlighted ? Theme.buttonPressedBackground : Theme.buttonHoverBackground).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Tokens.Radius.row, yRadius: Tokens.Radius.row).fill()
        }
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: Theme.windowText]
        let size = (title as NSString).size(withAttributes: titleAttributes)
        let titleY = isFlipped ? bounds.maxY - size.height - 4 : bounds.minY + 4
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: titleY), withAttributes: titleAttributes)
        guard let symbol = symbol?.withSymbolConfiguration(.init(pointSize: 19, weight: .regular)) else { return }
        let box = NSRect(
            x: bounds.midX - symbol.size.width / 2, y: isFlipped ? 6 : bounds.maxY - 6 - symbol.size.height, width: symbol.size.width,
            height: symbol.size.height)
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: box)
    }
}

/// A pop-up button drawn in the palette: the field color framed as the text fields are, with the arrows on a badge in the
/// accent (macOS draws its badge in its own accent). Only the bezel is ours: the title, the menu, the keyboard and
/// VoiceOver are AppKit's.
final class ThemedPopUpButtonCell: NSPopUpButtonCell {
    /// Makes `popUp` draw in the palette, keeping its cell (menu, selection, target) as it is: the cell becomes this
    /// subclass, which adds no state.
    static func adopt(_ popUp: NSPopUpButton) {
        guard let cell = popUp.cell as? NSPopUpButtonCell, !(cell is ThemedPopUpButtonCell), Swift.type(of: cell) == NSPopUpButtonCell.self,
            popUp.isBordered, popUp.bezelStyle == .push || popUp.bezelStyle == .flexiblePush
        else { return }
        object_setClass(cell, ThemedPopUpButtonCell.self)
        reattach(cell, to: popUp)
    }

    /// Makes `popUp` drawn by AppKit again (the native theme), keeping its cell as it is.
    static func release(_ popUp: NSPopUpButton) {
        guard let cell = popUp.cell as? ThemedPopUpButtonCell else { return }
        object_setClass(cell, NSPopUpButtonCell.self)
        reattach(cell, to: popUp)
    }

    /// The control works out how its cell draws (macOS's layer, or the cell's drawing) when it is given one: give it
    /// the same cell again, so it draws the new way from now on.
    private static func reattach(_ cell: NSPopUpButtonCell, to popUp: NSPopUpButton) {
        popUp.cell = NSPopUpButtonCell()
        popUp.cell = cell
        popUp.needsDisplay = true
    }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let height = min(frame.height - 4, controlSize == .small ? 18 : 21)
        let body = NSRect(x: frame.minX + 2.5, y: frame.midY - height / 2 + 0.5, width: frame.width - 5, height: height - 1)
        let radius: CGFloat = controlSize == .small ? 4 : 5
        let alpha: CGFloat = isEnabled ? 1 : 0.5
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        Theme.fieldBackground.withAlphaComponent(alpha).setFill()
        path.fill()
        Theme.frame.withAlphaComponent(alpha).setStroke()
        path.lineWidth = 1
        path.stroke()
        let side = body.height - 4
        let badge = NSRect(x: body.maxX - side - 2, y: body.midY - side / 2, width: side, height: side)
        Theme.accent.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: badge, xRadius: radius - 1.5, yRadius: radius - 1.5).fill()
        Theme.onAccent.withAlphaComponent(alpha).setStroke()
        // Offsets are up on screen, whichever way the view counts.
        let flipped = controlView.isFlipped
        func y(_ up: CGFloat) -> CGFloat { flipped ? badge.midY - up : badge.midY + up }
        let arrows = NSBezierPath()
        let w = side * 0.2, h = side * 0.14, gap = side * 0.12
        func chevron(pointingUp: Bool, at center: CGFloat) {
            let tip = pointingUp ? h / 2 : -h / 2
            arrows.move(to: NSPoint(x: badge.midX - w, y: y(center - tip)))
            arrows.line(to: NSPoint(x: badge.midX, y: y(center + tip)))
            arrows.line(to: NSPoint(x: badge.midX + w, y: y(center - tip)))
        }
        if pullsDown {
            chevron(pointingUp: false, at: 0)
        } else {
            chevron(pointingUp: true, at: (gap + h) / 2)
            chevron(pointingUp: false, at: -(gap + h) / 2)
        }
        arrows.lineWidth = 1.5
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        arrows.stroke()
    }
}
