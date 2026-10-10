import AppKit
import PorpoiseCore
import PorpoiseServices

/// KMessageWidget: an inline error/information message with an optional action button.
final class MessageBar: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let close = FlatButton(icon: "dialog-close", tooltip: "Close")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var actionHandler: (() -> Void)?
    var isError = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Theme.font
        label.textColor = Theme.windowText
        close.onClick = { [weak self] in self?.dismiss() }
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(runAction)
        actionButton.isHidden = true
        addSubview(label)
        addSubview(actionButton)
        addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called whenever the bar is shown or hidden (the container re-lays out).
    var onDismiss: (() -> Void)?

    @objc private func runAction() { actionHandler?() }

    func show(_ text: String, error: Bool, action: String? = nil, handler: (() -> Void)? = nil) {
        actionButton.title = action ?? ""
        actionButton.isHidden = action == nil
        actionHandler = handler
        actionButton.sizeToFit()
        label.stringValue = text
        isError = error
        isHidden = false
        // Same frame as last time means no automatic layout pass; the button and label still move.
        needsLayout = true
        needsDisplay = true
        onDismiss?()
    }

    func dismiss() { isHidden = true; onDismiss?() }
    var text: String { label.stringValue }

    override func layout() {
        super.layout()
        let aw = actionButton.isHidden ? 0 : actionButton.frame.width + 10
        actionButton.frame.origin = CGPoint(x: bounds.width - 40 - aw, y: (bounds.height - actionButton.frame.height) / 2)
        label.frame = CGRect(x: 34, y: 6, width: bounds.width - 76 - aw, height: bounds.height - 12)
        close.frame = CGRect(x: bounds.width - 34, y: (bounds.height - 26) / 2, width: 26, height: 26)
    }

    override func draw(_ dirty: NSRect) {
        let c = isError ? Theme.negativeText : Theme.neutralText
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 4, yRadius: 4)
        c.withAlphaComponent(0.2).setFill(); p.fill()
        c.setStroke(); p.stroke()
        Icons.shared.image(isError ? "dialog-error" : "dialog-information", size: 16)?
            .draw(in: CGRect(x: 14, y: bounds.midY - 8, width: 16, height: 16))
    }
}
