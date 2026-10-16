import AppKit

/// Chooser/missing-counterpart surface lives in the actual second pane, keeping navigation and history intact.
final class ComparePanePlaceholder: NSView {
    let content = ComparePlaceholder()
    private var recentButtons: [CompareActionButton] = []
    func setRecents(_ urls: [URL], choose: @escaping (URL) -> Void) {
        recentButtons.forEach { $0.removeFromSuperview() }; recentButtons = []
        for url in urls.prefix(5) {
            let button = CompareActionButton(title: "\(url.deletingLastPathComponent().lastPathComponent) › \(url.lastPathComponent)") { choose(url) }
            button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 12)
            button.image = Icons.shared.image("folder", size: 16); button.imagePosition = .imageLeft; button.toolTip = url.path
            addSubview(button); recentButtons.append(button)
        }
        needsLayout = true
    }
    let unlink = CompareActionButton(title: "Unlink", clicked: {})
    override init(frame: CGRect) {
        super.init(frame: frame); addSubview(content); addSubview(unlink); wantsLayer = true
        unlink.isHidden = true; unlink.isBordered = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) { Theme.viewBackground.setFill(); bounds.fill() }
    override func layout() {
        super.layout()
        content.frame = CGRect(
            x: max(4, (bounds.width - 340) / 2), y: max(35, (bounds.height - 225 - CGFloat(recentButtons.count * 28)) / 2),
            width: min(340, bounds.width - 8), height: 185)
        for (index, button) in recentButtons.enumerated() {
            button.frame = CGRect(
                x: max(8, (bounds.width - 280) / 2), y: content.frame.maxY + CGFloat(index * 28), width: min(280, bounds.width - 16), height: 28)
        }
        unlink.frame = CGRect(x: (bounds.width - 100) / 2, y: content.frame.maxY + 6, width: 100, height: 26)
    }
}
