import AppKit
import PorpoiseCore
import PorpoiseServices

/// Panel split view with a thin, Breeze-colored divider.
final class ThinSplitView: NSSplitView {
    var dividerColorOverride: NSColor?
    override var dividerColor: NSColor { dividerColorOverride ?? Theme.frame }
    override var dividerThickness: CGFloat { 1 }
}

final class DolphinWindow: NSWindow {
    /// Traffic-light placement of a macOS 26 window with a unified toolbar.
    private static let trafficLightsLeft: CGFloat = 16
    private static let trafficLightsSpacing: CGFloat = 20

    /// Keeps the traffic lights vertically centered in our taller, unified toolbar.
    func positionTrafficLights() {
        guard !styleMask.contains(.fullScreen),
            let close = standardWindowButton(.closeButton),
            let container = close.superview?.superview
        else { return }
        let h = Theme.toolbarHeight
        var f = container.frame
        f.size.height = h
        f.origin.y = frame.height - h
        container.frame = f
        for (i, t) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = standardWindowButton(t) else { continue }
            b.setFrameOrigin(NSPoint(x: Self.trafficLightsLeft + CGFloat(i) * Self.trafficLightsSpacing, y: (h - b.frame.height) / 2))
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionTrafficLights()
    }
}

/// Tab bar (when shown) on top of the current tab's views.
final class CenterColumnView: NSView {
    weak var tabBar: TabBarView?
    weak var host: NSView?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let t = tabBar, !t.isHidden {
            t.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TabBarView.height)
            y = TabBarView.height
        }
        guard let host else { return }
        host.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        host.subviews.forEach { $0.frame = host.bounds }
    }
}

/// Right-hand column next to the full-height sidebar: room for the toolbar (in the title bar) on top,
/// then the views, inspector and terminal.
final class MainColumnView: NSView {
    weak var content: NSView?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let th = Theme.toolbarHeight
        content?.frame = CGRect(x: 0, y: th, width: bounds.width, height: max(0, bounds.height - th))
    }
}

/// The root view: toolbar, tab bar, panels and tab content (flipped, laid out manually).
final class RootView: NSView {
    weak var controller: MainWindowController?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        controller?.layoutRoot()
    }
    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill()
        dirty.fill()
    }
}
