import AppKit

/// The top of the sidebar: Places and Folders as two tabs of one navigator, each at the sidebar's full height, with a
/// small segmented switch above them (as Xcode's navigators). The window decides which tab shows (`show`); the switch
/// only asks it to (`onChoose`), so F9, F7 and the View menu go through the same path as a click.
final class SidebarNavigator: NSView {
    enum Tab: String, CaseIterable {
        case places, folders

        var title: String { self == .places ? "Places" : "Folders" }
    }

    let picker = NSSegmentedControl(labels: Tab.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    /// A segment was clicked (or chosen with the keyboard); not called by `show`.
    var onChoose: ((Tab) -> Void)?
    private(set) var tab: Tab = .places
    private(set) var content: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // AppKit's own control in the native theme (DESIGN-CONTRACT N1); palette themes give it their accent below.
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        picker.segmentDistribution = .fillEqually
        picker.selectedSegment = 0
        picker.target = self
        picker.action = #selector(chosen)
        picker.setAccessibilityLabel("Sidebar")
        for t in Tab.allCases { picker.setToolTip("Show \(t.title)", forSegment: t.index) }
        picker.sizeToFit()
        addSubview(picker)
        Theme.whenChanged(self) { [weak self] in self?.picker.selectedSegmentBezelColor = Tokens.isNative ? nil : Theme.accent }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `view` as `tab`'s content (the one view the window keeps for it) and selects its segment.
    func show(_ tab: Tab, _ view: NSView) {
        self.tab = tab
        picker.selectedSegment = tab.index
        guard content !== view else { return }
        content?.removeFromSuperview()
        content = view
        addSubview(view)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        // Utility panels inside the window use 12-pt margins (DESIGN-CONTRACT S2); 8 above and below the switch.
        let inset = Tokens.Space.m, gap = Tokens.Space.s
        let h = picker.fittingSize.height
        picker.frame = CGRect(x: inset, y: bounds.height - gap - h, width: max(0, bounds.width - inset * 2), height: h)
        content?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, picker.frame.minY - gap))
    }

    @objc private func chosen() {
        guard let t = Tab.allCases[safe: picker.selectedSegment], t != tab else { return }
        onChoose?(t)
    }
}

extension SidebarNavigator.Tab {
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
