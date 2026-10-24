import AppKit
import PorpoiseServices

/// Secondary windows (`SecondaryWindowController`: Settings, Properties, Activity, Connect, Compare Files, the dialogs
/// and disk utilities) in the app's theme, as the main window is: its window color, also behind the title bar and
/// toolbar, its text colors, and its accent on native controls. They are dressed when they come to the front and again
/// whenever the look or the palette changes.
extension Theme {
    private static var watching = false

    /// Starts dressing themed windows as they come to the front (once, at launch).
    static func dressWindows() {
        guard !watching else { return }
        watching = true
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let window = n.object as? NSWindow else { return }
                MainActor.assumeIsolated { dressIfThemed(window) }
            }
        }
    }

    /// Every themed window (and a sheet on one): `lookChanged` calls it after a change of look or palette.
    static func redressWindows() {
        for window in NSApp.windows { dressIfThemed(window) }
    }

    static func dressIfThemed(_ window: NSWindow) {
        let owner = window.sheetParent ?? window
        guard isThemed(owner) || isThemed(window) else { return }
        dress(window)
    }

    private static func isThemed(_ window: NSWindow) -> Bool {
        window is SecondaryPanel || (window.windowController as? SecondaryWindowController)?.isThemed == true
    }

    /// The window color everywhere (a transparent title bar shows it behind the toolbar too), then every view.
    static func dress(_ window: NSWindow) {
        // Accents are kept as resolved colors by the controls: work them out in the look the window is drawn in.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = window is MaterialBackedWindow ? .clear : windowBackground.usingColorSpace(.sRGB) ?? windowBackground
            (window.contentViewController as? ThemedTabViewController)?.tintTabs()
            if let tabs = window.contentViewController as? NSTabViewController {
                // Pages not shown now are outside the window's views.
                for item in tabs.tabViewItems { if let view = item.viewController?.view { dress(view) } }
            }
            if let view = window.contentView { dress(view) }
        }
        window.contentView?.redrawAll()
    }

    /// Views given a resolved palette color, to give them the new one when the palette changes.
    private static let themed = NSHashTable<NSView>.weakObjects()

    /// `color` as it looks now, as a plain sRGB color (what controls that keep a color can use).
    private static func resolved(_ color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(srgbRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    /// The accent as the controls keep it (they don't re-resolve a dynamic color when the palette changes).
    private static var resolvedAccent: NSColor { resolved(accent) }

    /// The view and everything in it: system colors become the palette's, the system accent the theme's. Colors a
    /// view was given on purpose (anything not a system color) are left as they are. The native theme's colors are the
    /// system's already, and its controls are AppKit's own: there it only undoes what a palette theme changed.
    static func dress(_ view: NSView) {
        guard !Tokens.isNative else { return undress(view) }
        switch view {
        case let field as NSTextField: dress(field)
        case let segments as NSSegmentedControl:
            remember(segments) { $0.color = segments.selectedSegmentBezelColor }
            segments.selectedSegmentBezelColor = resolvedAccent
        case let slider as NSSlider:
            remember(slider) { $0.color = slider.trackFillColor }
            slider.trackFillColor = resolvedAccent
        case let popUp as NSPopUpButton:
            ThemedPopUpButtonCell.adopt(popUp)  // its menu follows the light or dark look
        case let button as NSButton: dress(button)
        case let box as NSBox where box.boxType == .custom:
            if isSystem(box.fillColor, Self.backgroundColors) { remember(box) { $0.color = box.fillColor }; box.fillColor = viewBackground }
            if isSystem(box.borderColor, [.separatorColor, .gridColor]) { remember(box) { $0.border = box.borderColor }; box.borderColor = frame }
        case let table as NSTableView:
            // The system's alternating rows can't take the palette: plain view color, as the main window's lists.
            if themed.contains(table) || isSystem(table.backgroundColor, Self.backgroundColors) {
                themed.add(table)
                remember(table) {
                    $0.color = table.backgroundColor
                    $0.flag = table.usesAlternatingRowBackgroundColors
                }
                table.usesAlternatingRowBackgroundColors = false
                table.backgroundColor = resolved(viewBackground)
            }
            dressHeader(table)
        case let scroll as NSScrollView:
            if scroll.drawsBackground, isSystem(scroll.backgroundColor, Self.backgroundColors) {
                remember(scroll) { $0.color = scroll.backgroundColor }
                scroll.backgroundColor = viewBackground
            }
        case let clip as NSClipView:
            if clip.drawsBackground, isSystem(clip.backgroundColor, Self.backgroundColors) {
                remember(clip) { $0.color = clip.backgroundColor }
                clip.backgroundColor = viewBackground
            }
        case let text as NSTextView:
            if isSystem(text.textColor, Self.primaryText) { remember(text) { $0.text = text.textColor }; text.textColor = viewText }
            if text.drawsBackground, isSystem(text.backgroundColor, Self.backgroundColors) {
                remember(text) { $0.color = text.backgroundColor }
                text.backgroundColor = fieldBackground
            }
            remember(text) { $0.border = text.insertionPointColor }
            text.insertionPointColor = viewText
        default: break
        }
        for subview in view.subviews { dress(subview) }
    }

    private static func dress(_ field: NSTextField) {
        if field.isEditable || field.isBezeled {
            if isSystem(field.textColor, primaryText) { remember(field) { $0.text = field.textColor }; field.textColor = viewText }
            // Fields keep their background as it was resolved: set it again, resolved, on every change.
            if field.drawsBackground, themed.contains(field) || isSystem(field.backgroundColor, backgroundColors) {
                themed.add(field)
                remember(field) { $0.color = field.backgroundColor }
                field.backgroundColor = resolved(fieldBackground)
            }
        } else if isSystem(field.textColor, primaryText) {
            remember(field) { $0.text = field.textColor }
            field.textColor = windowText
        } else if isSystem(field.textColor, secondaryText) {
            remember(field) { $0.text = field.textColor }
            field.textColor = windowTextInactive
        }
    }

    private static func dress(_ button: NSButton) {
        if isChoice(button) {
            dressChoice(button)
            // The title in the palette's text color, unless it was given its own.
            let title = button.attributedTitle
            let color = title.length > 0 ? title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
            if title.length > 0, color == nil || isSystem(color, primaryText) {
                remember(button) { $0.title = title }
                let colored = NSMutableAttributedString(attributedString: title)
                colored.addAttribute(.foregroundColor, value: windowText, range: NSRange(location: 0, length: colored.length))
                button.attributedTitle = colored
            }
        } else if button.keyEquivalent == "\r" {
            remember(button) { $0.color = button.bezelColor }
            button.bezelColor = resolvedAccent  // the default button, in the accent as the system's would be
        }
    }

    // MARK: Back to the native theme

    /// What a view looked like before a palette theme dressed it, to give it back in the native theme.
    private final class Original {
        var color: NSColor??
        var border: NSColor??
        var text: NSColor??
        var flag: Bool?
        var title: NSAttributedString?
    }

    private static let originals = NSMapTable<NSView, Original>.weakToStrongObjects()

    /// Records, once, what `view` had before it was first dressed (a later dressing must not record the palette's).
    private static func remember(_ view: NSView, _ record: (Original) -> Void) {
        let original = originals.object(forKey: view) ?? Original()
        let fresh = Original()
        record(fresh)
        if original.color == nil, let c = fresh.color { original.color = c }
        if original.border == nil, let c = fresh.border { original.border = c }
        if original.text == nil, let c = fresh.text { original.text = c }
        if original.flag == nil { original.flag = fresh.flag }
        if original.title == nil { original.title = fresh.title }
        originals.setObject(original, forKey: view)
    }

    /// The view and everything in it as AppKit drew them before any palette theme: the controls macOS draws, in the
    /// system's colors and accent.
    static func undress(_ view: NSView) {
        if let original = originals.object(forKey: view) {
            originals.removeObject(forKey: view)
            themed.remove(view)
            restore(view, original)
        }
        switch view {
        case let popUp as NSPopUpButton: ThemedPopUpButtonCell.release(popUp)
        case let button as NSButton: undressChoice(button)
        case let table as NSTableView: undressHeader(table)
        default: break
        }
        for subview in view.subviews { undress(subview) }
    }

    private static func restore(_ view: NSView, _ o: Original) {
        switch view {
        case let field as NSTextField:
            if let c = o.text { field.textColor = c }
            if let c = o.color { field.backgroundColor = c }
        case let segments as NSSegmentedControl:
            if let c = o.color { segments.selectedSegmentBezelColor = c }
        case let slider as NSSlider:
            if let c = o.color { slider.trackFillColor = c }
        case let button as NSButton:
            if let t = o.title { button.attributedTitle = t }
            if let c = o.color { button.bezelColor = c }
        case let box as NSBox:
            if let c = o.color { box.fillColor = c ?? .clear }
            if let c = o.border { box.borderColor = c ?? .clear }
        case let table as NSTableView:
            if let c = o.color { table.backgroundColor = c ?? .controlBackgroundColor }
            if let f = o.flag { table.usesAlternatingRowBackgroundColors = f }
        case let scroll as NSScrollView:
            if let c = o.color { scroll.backgroundColor = c ?? .controlBackgroundColor }
        case let clip as NSClipView:
            if let c = o.color { clip.backgroundColor = c ?? .controlBackgroundColor }
        case let text as NSTextView:
            if let c = o.text { text.textColor = c }
            if let c = o.color { text.backgroundColor = c ?? .textBackgroundColor }
            if let c = o.border { text.insertionPointColor = c ?? .textColor }
        default: break
        }
    }

    /// A checkbox or radio button, as it tells VoiceOver.
    static func isChoice(_ button: NSButton) -> Bool {
        [.checkBox, .radioButton].contains(button.cell?.accessibilityRole())
    }

    static let primaryText: [NSColor] = [.labelColor, .controlTextColor, .textColor, .headerTextColor, .windowFrameTextColor]
    static let secondaryText: [NSColor] = [.secondaryLabelColor, .tertiaryLabelColor, .quaternaryLabelColor, .placeholderTextColor]
    static let backgroundColors: [NSColor] = [.controlBackgroundColor, .textBackgroundColor, .windowBackgroundColor, .underPageBackgroundColor]

    /// `color` is one of these system colors (a palette color never is).
    static func isSystem(_ color: NSColor?, _ system: [NSColor]) -> Bool {
        guard let color else { return false }
        return system.contains { $0 == color }
    }
}

/// A plain background in the window color, for content that replaces a window's own (sheets draw a material).
final class ThemedBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Theme.windowBackground.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
