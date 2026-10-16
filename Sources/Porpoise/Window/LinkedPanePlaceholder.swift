import AppKit

final class LinkedPanePlaceholder: NSView {
    final class Content: NSView {
        let image = NSImageView()
        let title = NSTextField(labelWithString: "")
        let detail = NSTextField(wrappingLabelWithString: "")
        let button = ClosureButton(title: "Create Folder") { _ in }
        func configure(symbol: String, title: String, detail: String, button: String, action: @escaping () -> Void) {
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            self.title.stringValue = title; self.detail.stringValue = detail; self.button.title = button
            self.button.handler = { _ in action() }
        }
        override init(frame: CGRect) {
            super.init(frame: frame)
            title.font = .systemFont(ofSize: 15, weight: .semibold); title.alignment = .center; detail.alignment = .center
            for view in [image, title, detail, button] { addSubview(view) }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            image.frame = CGRect(x: (bounds.width - 48) / 2, y: 174, width: 48, height: 48)
            title.frame = CGRect(x: 8, y: 130, width: bounds.width - 16, height: 42)
            detail.frame = CGRect(x: 16, y: 65, width: bounds.width - 32, height: 60)
            button.frame = CGRect(x: 12, y: 28, width: bounds.width - 24, height: 28)
        }
    }
    let content = Content()
    let unlink = LinkedActionButton(title: "Unlink")
    let choose = LinkedActionButton(title: "Choose Folder…")
    private let status = NSTextField(labelWithString: "")
    var statusText = "" { didSet { status.stringValue = statusText } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        status.font = .systemFont(ofSize: 11); status.textColor = Theme.windowTextInactive
        for view in [content, unlink, choose, status] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) { Theme.viewBackground.setFill(); bounds.fill() }
    override func layout() {
        super.layout()
        content.frame = CGRect(x: 8, y: max(50, (bounds.height - 280) / 2), width: max(0, bounds.width - 16), height: 225)
        unlink.frame = CGRect(x: bounds.midX - 118, y: content.frame.minY - 10, width: 70, height: 28)
        status.frame = CGRect(x: 12, y: 6, width: max(0, bounds.width - 24), height: 18)
        choose.frame = CGRect(x: bounds.midX - 40, y: content.frame.minY - 10, width: 158, height: 28)
    }
}

final class LinkedActionButton: NSButton {
    var onClick: (() -> Void)?
    init(title: String) {
        super.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self; action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { onClick?() }
}
