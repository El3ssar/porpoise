import AppKit

/// A clickable part of a custom-drawn view (a tab, a path crumb, a grid cell) for VoiceOver: its label, where it is,
/// whether it's selected, and what "press" does. Frames are in the parent view's coordinates.
final class AccessibleRegion: NSAccessibilityElement {
    private weak var view: NSView?
    private let label: String
    private let frame: () -> CGRect
    private let selected: () -> Bool
    private let select: ((Bool) -> Void)?
    private let showMenu: (() -> Bool)?
    private let press: () -> Void

    init(
        in view: NSView, role: NSAccessibility.Role, label: String, frame: @escaping () -> CGRect,
        selected: @escaping () -> Bool = { false }, select: ((Bool) -> Void)? = nil, showMenu: (() -> Bool)? = nil, press: @escaping () -> Void
    ) {
        self.view = view
        self.label = label
        self.frame = frame
        self.selected = selected
        self.select = select
        self.showMenu = showMenu
        self.press = press
        super.init()
        setAccessibilityParent(view)
        setAccessibilityRole(role)
    }

    override func accessibilityLabel() -> String? { label }
    override func isAccessibilitySelected() -> Bool { selected() }
    override func setAccessibilitySelected(_ selected: Bool) { select?(selected) }
    override func accessibilityPerformShowMenu() -> Bool { showMenu?() ?? false }
    override func accessibilityFrameInParentSpace() -> NSRect { frame() }

    override func accessibilityFrame() -> NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(frame(), to: nil))
    }

    override func accessibilityPerformPress() -> Bool { press(); return true }
}
