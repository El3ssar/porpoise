import AppKit
import PorpoiseServices

/// Secondary windows (Settings, Properties, Activity, Connect, Compare Files, the disk utilities) in the app's theme,
/// as the main window is: its window color, also behind the title bar and toolbar, its text colors, and its accent on
/// native controls. They are dressed when they come to the front and again whenever the look or the palette changes.
protocol ThemedWindowController: NSWindowController {}

extension SettingsWindowController: ThemedWindowController {}
extension PropertiesWindow: ThemedWindowController {}
extension ActivityWindowController: ThemedWindowController {}
extension ConnectSheet: ThemedWindowController {}
extension FileDiffWindow: ThemedWindowController {}
extension DiskUtilityWindow: ThemedWindowController {}
extension OnboardingWindowController: ThemedWindowController {}

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
        guard owner.windowController is ThemedWindowController || window.windowController is ThemedWindowController else { return }
        dress(window)
    }

    /// The window color everywhere (a transparent title bar shows it behind the toolbar too), then every view.
    static func dress(_ window: NSWindow) {
        // Accents are kept as resolved colors by the controls: work them out in the look the window is drawn in.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = windowBackground.usingColorSpace(.sRGB) ?? windowBackground
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
    /// view was given on purpose (anything not a system color) are left as they are.
    static func dress(_ view: NSView) {
        switch view {
        case let field as NSTextField: dress(field)
        case let segments as NSSegmentedControl:
            segments.selectedSegmentBezelColor = resolvedAccent
        case let slider as NSSlider:
            slider.trackFillColor = resolvedAccent
        case let popUp as NSPopUpButton:
            _ = popUp  // macOS draws it; its menu follows the light or dark look
        case let button as NSButton: dress(button)
        case let box as NSBox where box.boxType == .custom:
            if isSystem(box.fillColor, Self.backgroundColors) { box.fillColor = viewBackground }
            if isSystem(box.borderColor, [.separatorColor, .gridColor]) { box.borderColor = frame }
        case let table as NSTableView:
            // The system's alternating rows can't take the palette: plain view color, as the main window's lists.
            if themed.contains(table) || isSystem(table.backgroundColor, Self.backgroundColors) {
                themed.add(table)
                table.usesAlternatingRowBackgroundColors = false
                table.backgroundColor = resolved(viewBackground)
            }
        case let scroll as NSScrollView:
            if scroll.drawsBackground, isSystem(scroll.backgroundColor, Self.backgroundColors) { scroll.backgroundColor = viewBackground }
        case let clip as NSClipView:
            if clip.drawsBackground, isSystem(clip.backgroundColor, Self.backgroundColors) { clip.backgroundColor = viewBackground }
        case let text as NSTextView:
            if isSystem(text.textColor, Self.primaryText) { text.textColor = viewText }
            if text.drawsBackground, isSystem(text.backgroundColor, Self.backgroundColors) { text.backgroundColor = fieldBackground }
            text.insertionPointColor = viewText
        default: break
        }
        for subview in view.subviews { dress(subview) }
    }

    private static func dress(_ field: NSTextField) {
        if field.isEditable || field.isBezeled {
            if isSystem(field.textColor, primaryText) { field.textColor = viewText }
            // Fields keep their background as it was resolved: set it again, resolved, on every change.
            if field.drawsBackground, themed.contains(field) || isSystem(field.backgroundColor, backgroundColors) {
                themed.add(field)
                field.backgroundColor = resolved(fieldBackground)
            }
        } else if isSystem(field.textColor, primaryText) {
            field.textColor = windowText
        } else if isSystem(field.textColor, secondaryText) {
            field.textColor = windowTextInactive
        }
    }

    private static func dress(_ button: NSButton) {
        if isChoice(button) {
            if button.bezelColor != resolvedAccent {
                button.bezelColor = resolvedAccent
                // Its box is an image made in the accent of the time it was first drawn: drop it, it's made again.
                button.image = nil
                button.alternateImage = nil
            }
            // The title in the palette's text color, unless it was given its own.
            let title = button.attributedTitle
            let color = title.length > 0 ? title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
            if title.length > 0, color == nil || isSystem(color, primaryText) {
                let colored = NSMutableAttributedString(attributedString: title)
                colored.addAttribute(.foregroundColor, value: windowText, range: NSRange(location: 0, length: colored.length))
                button.attributedTitle = colored
            }
        } else if button.keyEquivalent == "\r" {
            button.bezelColor = resolvedAccent  // the default button, in the accent as the system's would be
        }
    }

    /// A checkbox or radio button: ours say so; others are borderless with the box before the title, its image (once
    /// drawn) the system's own.
    static func isChoice(_ button: NSButton) -> Bool {
        if let ours = button as? ClosureButton { return ours.isToggle }
        guard !button.isBordered, button.imagePosition == .imageLeading else { return false }
        guard let image = button.image else { return true }
        return image.representations.contains { String(describing: type(of: $0)).contains("CoreUI") }
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
