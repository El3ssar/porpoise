import AppKit
import PorpoiseCore
import PorpoiseServices

/// Dolphin's selection mode (Space in Dolphin; menu/hamburger here): a top bar explaining the mode and a
/// bottom bar with actions for the selection.
final class SelectionTopBar: NSView {
    private static let defaultPrompt = "Selection Mode: Click on files or folders to select or deselect them."
    private let label = NSTextField(labelWithString: SelectionTopBar.defaultPrompt)
    private let exit = FlatButton(icon: "dialog-close", title: "Exit Selection Mode", tooltip: "Exit Selection Mode")
    var onExit: (() -> Void)?
    /// Replaces the default explanation (e.g. the paste reminder); nil restores it.
    var prompt: String? { didSet { label.stringValue = prompt ?? Self.defaultPrompt } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Theme.font
        label.textColor = Theme.windowText
        label.lineBreakMode = .byTruncatingTail
        exit.onClick = { [weak self] in self?.onExit?() }
        addSubview(label)
        addSubview(exit)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // A narrow view keeps room for the explanation: the exit button shows its icon only.
        exit.showsTitle = bounds.width >= exit.width(showingTitle: true) + 240
        let w = exit.intrinsicContentSize.width
        exit.frame = CGRect(x: bounds.width - w - 8, y: (bounds.height - 28) / 2, width: w, height: 28)
        label.frame = CGRect(x: 12, y: (bounds.height - 18) / 2, width: exit.frame.minX - 20, height: 18)
    }

    override func draw(_ dirty: NSRect) {
        Theme.selection.withAlphaComponent(0.35).setFill()
        bounds.fill()
        Theme.frame.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Action buttons for the selection; they send their selectors up the responder chain.
final class SelectionBottomBar: NSView {
    private var buttons: [FlatButton] = []
    var actions: [(title: String, icon: String, selector: Selector)] = [] { didSet { rebuild() } }
    var enabled = false { didSet { buttons.forEach { $0.isEnabled = enabled } } }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { a in
            let b = FlatButton(icon: a.icon, title: a.title, tooltip: a.title)
            b.action = a.selector
            b.target = nil
            b.isEnabled = enabled
            addSubview(b)
            return b
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // In a narrow view (e.g. one side of a split) the buttons show icons only, so all of them stay reachable.
        let titled = buttons.reduce(16) { $0 + $1.width(showingTitle: true) + 4 } <= bounds.width
        var x: CGFloat = 8
        for b in buttons {
            b.showsTitle = titled
            let w = b.intrinsicContentSize.width
            b.frame = CGRect(x: x, y: (bounds.height - 28) / 2, width: w, height: 28)
            x += w + 4
        }
    }

    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()
        Theme.frame.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }
}
