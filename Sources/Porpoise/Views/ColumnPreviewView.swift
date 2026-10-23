import AppKit
import PorpoiseServices

/// Column view's last column when one file is selected: the Information panel's content for it (its large preview,
/// a video or song to play, name and details), on the view's background, as Finder's preview column.
final class ColumnPreviewView: NSView {
    let information = InformationPanel()
    /// The file shown (nil: none).
    private(set) var shownURL: URL?
    private weak var container: ViewContainer?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        information.showsMaterial = false
        addSubview(information)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Preview")
        Theme.whenChanged(self) { [weak self] in self?.layer?.backgroundColor = Theme.viewBackground.cgColor }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        information.frame = bounds
    }

    /// Shows the focused column's one selected file.
    func show(_ url: URL, container: ViewContainer) {
        self.container = container
        guard url != shownURL else { return }
        shownURL = url
        information.show(hovered: nil, container: container)
    }

    func clear() { shownURL = nil; container = nil }

    /// Out of the window, the panel stops what plays and forgets what it showed: shown again, it reads it afresh.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            shownURL = nil
        } else if let container, container.model.selection.count == 1, let item = container.model.selectedItems.first {
            // Docking the window inspector temporarily reparents the pane; its selected file still owns this
            // preview column. Re-show it after attachment rather than leaving a blank or stale column.
            show(item.url, container: container)
        }
    }
}
