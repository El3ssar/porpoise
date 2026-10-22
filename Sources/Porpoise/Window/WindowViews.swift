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

    // MARK: Tab order

    /// AppKit's key-view loop covers the window's content, not the title bar: the path field (when it takes focus,
    /// with Full Keyboard Access) comes in just before the file list, so Tab goes … → path → list and ⇧Tab back.
    private var pathViews: [NSView] {
        guard let frame = contentView?.superview else { return [] }
        func find(_ v: NSView) -> [NSView] { v is BreadcrumbView ? [v] : v.subviews.flatMap(find) }
        return find(frame).filter(\.canBecomeKeyView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private var listView: NSView? { (windowController as? MainWindowController)?.view.list }

    override func selectNextKeyView(_ sender: Any?) {
        let path = pathViews
        guard !path.isEmpty, let list = listView, let current = firstResponder as? NSView else { return super.selectNextKeyView(sender) }
        if let i = path.firstIndex(of: current) {
            makeFirstResponder(i + 1 < path.count ? path[i + 1] : list)
        } else if current.nextValidKeyView === list {
            makeFirstResponder(path[0])
        } else {
            super.selectNextKeyView(sender)
        }
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        let path = pathViews
        guard !path.isEmpty, let list = listView, let current = firstResponder as? NSView else {
            return super.selectPreviousKeyView(sender)
        }
        if let i = path.firstIndex(of: current) {
            if i > 0 { makeFirstResponder(path[i - 1]) } else if let before = list.previousValidKeyView { makeFirstResponder(before) }
        } else if current === list {
            makeFirstResponder(path[path.count - 1])
        } else {
            super.selectPreviousKeyView(sender)
        }
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
