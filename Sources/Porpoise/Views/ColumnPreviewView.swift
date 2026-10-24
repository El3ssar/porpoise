import AppKit
import PorpoiseServices

/// Column view's last column when one file is selected: the Information panel's content for it (its large preview,
/// a video or song to play, name and details), on the view's background, as Finder's preview column.
final class ColumnPreviewView: NSView {
    let information = InformationPanel()
    /// The file shown (nil: none).
    private(set) var shownURL: URL?

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

    /// The preview, name and details stay one block of this width at most, centred in the column (Finder): in a
    /// wide window the column takes the rest of the strip, and the details would sit far from the picture.
    static let contentWidth: CGFloat = 420

    override func layout() {
        super.layout()
        let w = min(bounds.width, Self.contentWidth)
        information.frame = CGRect(x: floor((bounds.width - w) / 2), y: 0, width: w, height: bounds.height)
    }

    /// Shows the focused column's one selected file.
    func show(_ url: URL, container: ViewContainer) {
        guard url != shownURL else { return }
        shownURL = url
        information.show(hovered: nil, container: container)
    }

    func clear() { shownURL = nil }

    /// Out of the window, the panel stops what plays and forgets what it showed: shown again, it reads it afresh.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { shownURL = nil }
    }
}
