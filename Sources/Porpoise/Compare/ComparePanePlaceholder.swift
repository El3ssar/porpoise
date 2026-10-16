import AppKit

/// Chooser/missing-counterpart surface lives in the actual second pane, keeping navigation and history intact.
final class ComparePanePlaceholder: NSView {
    let content = ComparePlaceholder()
    private var recentButtons: [CompareActionButton] = []
    private let recentFrame = NSView()
    private let recentHeading = NSTextField(labelWithString: "Recent")
    private let dropHint = NSTextField(labelWithString: "Or drop a folder here.")
    private let status = NSTextField(labelWithString: "")
    var statusText: String = "" { didSet { status.stringValue = statusText } }
    func setRecents(_ urls: [URL], choose: @escaping (URL) -> Void) {
        recentButtons.forEach { $0.removeFromSuperview() }; recentButtons = []
        for url in urls.prefix(5) {
            let button = CompareActionButton(title: "\(url.deletingLastPathComponent().lastPathComponent) › \(url.lastPathComponent)") { choose(url) }
            button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 12)
            button.image = Icons.shared.image("folder", size: 16); button.imagePosition = .imageLeft; button.toolTip = url.path
            recentFrame.addSubview(button); recentButtons.append(button)
        }
        needsLayout = true
    }
    let unlink = CompareActionButton(title: "Unlink", clicked: {})
    override init(frame: CGRect) {
        super.init(frame: frame); wantsLayer = true
        for view in [content, recentHeading, recentFrame, dropHint, unlink, status] { addSubview(view) }
        recentFrame.wantsLayer = true; recentFrame.layer?.cornerRadius = 6; recentFrame.layer?.borderWidth = 1
        recentHeading.font = .systemFont(ofSize: 11); dropHint.font = .systemFont(ofSize: 11); dropHint.alignment = .center
        status.font = .systemFont(ofSize: 11)
        Theme.whenChanged(self) { [weak self] in
            guard let self else { return }
            self.recentFrame.layer?.borderColor = Theme.hairline.cgColor
            for label in [self.recentHeading, self.dropHint, self.status] { label.textColor = Theme.windowTextInactive }
            self.unlink.contentTintColor = Theme.accent
            for (index, button) in self.recentButtons.enumerated() {
                button.wantsLayer = true; button.layer?.backgroundColor = index == 0 ? Theme.selection.withAlphaComponent(0.24).cgColor : nil
            }
        }
        unlink.isHidden = true; unlink.isBordered = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            if let recent = recentButtons.first { recent.performClick(nil) } else { content.performPrimaryAction() }
        } else {
            super.keyDown(with: event)
        }
    }
    override func draw(_ dirty: NSRect) {
        Theme.viewBackground.setFill(); bounds.fill()
        Theme.windowBackground.setFill(); CGRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 28).fill()
        Theme.hairline.setFill(); CGRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 1).fill()
    }
    override func layout() {
        super.layout()
        let chooser = unlink.isHidden, rowsHeight = CGFloat(recentButtons.count * 28)
        content.secondaryActionWidth = chooser ? 0 : 76
        content.frame = CGRect(
            x: max(4, (bounds.width - 340) / 2), y: max(35, (bounds.height - 260 - (chooser ? rowsHeight : 0)) / 2),
            width: min(340, bounds.width - 8), height: 185)
        content.layoutSubtreeIfNeeded()
        recentHeading.isHidden = !chooser || recentButtons.isEmpty; recentFrame.isHidden = recentHeading.isHidden
        dropHint.isHidden = !chooser
        let listWidth = min(280, bounds.width - 16), listX = max(8, (bounds.width - listWidth) / 2)
        recentHeading.frame = CGRect(x: listX, y: content.frame.maxY + 6, width: listWidth, height: 16)
        recentFrame.frame = CGRect(x: listX, y: recentHeading.frame.maxY + 4, width: listWidth, height: rowsHeight)
        for (index, button) in recentButtons.enumerated() {
            button.frame = CGRect(x: 0, y: CGFloat(recentButtons.count - index - 1) * 28, width: listWidth, height: 28)
            button.wantsLayer = true; button.layer?.backgroundColor = index == 0 ? Theme.selection.withAlphaComponent(0.24).cgColor : nil
            if index == 0, !button.title.hasSuffix("  ↩") { button.title += "  ↩" }
        }
        dropHint.frame = CGRect(x: listX, y: (recentButtons.isEmpty ? content.frame.maxY : recentFrame.frame.maxY) + 10, width: listWidth, height: 20)
        let primary = content.convert(content.button.frame, to: self)
        unlink.frame = CGRect(x: primary.maxX + 8, y: primary.minY + 1, width: 68, height: 26)
        status.frame = CGRect(x: 12, y: bounds.height - 23, width: max(0, bounds.width - 24), height: 18)
    }
}
