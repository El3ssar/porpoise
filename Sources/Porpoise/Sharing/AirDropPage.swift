import AppKit
import PorpoiseServices

/// A pane location; device discovery and sending remain in the public system sharing sheet.
final class AirDropPage: NSView {
    private let scroll = NSScrollView()
    private let content = AirDropCanvas()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "AirDrop")
    private let prompt = NSTextField(wrappingLabelWithString: "Drop files to send with AirDrop")
    private let detail = NSTextField(wrappingLabelWithString: "Choose a nearby recipient in the system AirDrop sheet.")
    let chooseButton = NSButton(title: "Choose Files…", target: nil, action: nil)
    let selectionButton = NSButton(title: "Send Selection", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "Change who can discover this Mac in Control Center’s AirDrop controls.")
    var selection: () -> [URL] = { [] }
    var selectionAllowed = true
    var selectionAvailable: () -> Bool = { false }
    var choose: ((NSWindow, @escaping ([URL]) -> Void) -> Void)?
    var onActivate: (() -> Void)?
    var onSend: (([URL], NSView) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = content
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        for view in [icon, title, prompt, detail, chooseButton, selectionButton, hint] as [NSView] { content.addSubview(view) }
        title.font = Tokens.font(.largeTitle, weight: .semibold)
        prompt.font = Tokens.font(.title2, weight: .medium)
        detail.font = Tokens.font(.body)
        hint.font = Tokens.font(.callout)
        for label in [title, prompt, detail, hint] { label.alignment = .center }
        for button in [chooseButton, selectionButton] { button.bezelStyle = .rounded; button.target = self }
        chooseButton.action = #selector(chooseFiles)
        selectionButton.action = #selector(sendSelection)
        registerForDraggedTypes(DropTargetPolicy.types)
        setAccessibilityElement(false)
        setAccessibilityLabel("AirDrop")
        chooseButton.setAccessibilityHelp("Choose files or folders to send with AirDrop.")
        selectionButton.setAccessibilityHelp("Send the other pane’s selection, or the selection from before opening AirDrop.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(chooseButton) ?? false }

    func refreshSelection() { selectionButton.isEnabled = selectionAllowed && selectionAvailable() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = max(1, bounds.width), height = max(390, bounds.height)
        content.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let textWidth = max(1, min(440, width - 64))
        var y = max(38, (height - 330) / 2)
        icon.image = Icons.shared.image("airdrop", size: 64)
        icon.frame = CGRect(x: (width - 64) / 2, y: y, width: 64, height: 64); y += 76
        func label(_ label: NSTextField, spacing: CGFloat) {
            label.textColor = label === title || label === prompt ? Theme.viewText : Theme.viewTextInactive
            label.preferredMaxLayoutWidth = textWidth
            let size = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: 1000)) ?? .zero
            label.frame = CGRect(x: (width - textWidth) / 2, y: y, width: textWidth, height: ceil(size.height))
            y += ceil(size.height) + spacing
        }
        label(title, spacing: 12); label(prompt, spacing: 6); label(detail, spacing: 18)
        for button in [chooseButton, selectionButton] {
            button.frame = CGRect(x: (width - min(164, textWidth)) / 2, y: y, width: min(164, textWidth), height: 32)
            y += 40
        }
        label(hint, spacing: 20)
        if y + 24 > height { content.frame.size.height = y + 24 }
        refreshSelection()
        content.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { onActivate?(); window?.makeFirstResponder(chooseButton) }

    @objc func chooseFiles() {
        onActivate?()
        guard let window else { return }
        if let choose {
            choose(window) { [weak self] in self?.send($0) }
            return
        }
        let panel = Self.fileChooser()
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.send(panel.urls) }
        }
    }
    static func fileChooser() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Send with AirDrop"; panel.prompt = "Choose"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        return panel
    }
    @objc func sendSelection() { send(selection()) }
    func send(_ urls: [URL]) {
        guard SharingPreparation.supports(urls) else { return }
        onActivate?()
        onSend?(urls, self)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = SharingPreparation.supports(DropTargetPolicy.urls(sender))
        content.highlighted = accepted
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { content.highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        content.highlighted = false
        let urls = DropTargetPolicy.urls(sender)
        guard SharingPreparation.supports(urls) else { return false }
        send(urls)
        return true
    }
}

private final class AirDropCanvas: NSView {
    var highlighted = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.viewBackground.setFill(); bounds.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 20, dy: 20), xRadius: 16, yRadius: 16)
        (highlighted ? NSColor.controlAccentColor : Theme.viewTextInactive.withAlphaComponent(0.22)).setStroke()
        border.lineWidth = highlighted ? 2 : 1
        border.setLineDash([6, 5], count: 2, phase: 0)
        border.stroke()
    }
}
