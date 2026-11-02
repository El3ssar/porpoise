import AppKit
import PorpoiseCore
import PorpoiseServices

final class EditActivityRowView: NSView {
    static let conflictHeight: CGFloat = 92
    /// Rows with a choice to make: the explanation on two lines, the buttons under it.
    static func isTall(_ mark: CloudEditMark) -> Bool { mark == .conflict }
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let badge = NSImageView()
    private let buttons = NSStackView()
    private let close = NSButton()
    private var entry: CloudEditEntry?
    private var shownButtons: [EditActivityAction] = []
    private var shownService = ""
    private let alternate: Bool

    override var isFlipped: Bool { true }

    init(alternate: Bool) {
        self.alternate = alternate
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: Tokens.FontSize.body)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: Tokens.FontSize.small)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyDown
        buttons.spacing = Tokens.Space.s
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from the list")
        close.contentTintColor = Theme.windowTextInactive
        close.target = self
        close.action = #selector(dismiss)
        for v in [icon, badge, title, detail, buttons, close] as [NSView] { addSubview(v) }
        Theme.whenChanged(self) { [weak self] in
            guard let self, let entry = self.entry else { return }
            self.update(entry)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 16, y: 10, width: 32, height: 32)
        badge.frame = CGRect(x: 36, y: 28, width: 16, height: 16)
        close.frame = CGRect(x: bounds.width - 34, y: 14, width: 22, height: 22)
        let right = close.isHidden ? bounds.width - 12 : close.frame.minX - 8
        let conflict = entry.map { Self.isTall($0.mark) } ?? false
        title.frame = CGRect(x: 60, y: 9, width: max(0, right - 60), height: 17)
        detail.frame = CGRect(x: 60, y: 27, width: max(0, (conflict ? bounds.width - 12 : right) - 60), height: conflict ? 30 : 15)
        let size = buttons.fittingSize
        buttons.frame =
            conflict
            ? CGRect(x: 60, y: 58, width: size.width, height: 26)
            : CGRect(x: right - size.width, y: 13, width: size.width, height: 26)
        if !conflict, !buttons.arrangedSubviews.isEmpty {
            title.frame.size.width = max(0, buttons.frame.minX - 8 - 60)
            detail.frame.size.width = title.frame.width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ActivityRowStyle.background(alternate: alternate).setFill()
        bounds.fill()
    }

    func update(_ e: CloudEditEntry) {
        if entry?.id != e.id { icon.image = NSWorkspace.shared.icon(forFile: e.localURL.path) }
        entry = e
        title.attributedStringValue = ActivityRowStyle.title(e.title)
        title.toolTip = e.title
        detail.stringValue = e.detail
        detail.textColor = e.mark.needsAttention ? Theme.transferDanger : e.mark == .saved ? Theme.transferPositive : Theme.viewTextInactive
        let tint: NSColor = e.mark.needsAttention ? Theme.transferDanger : e.mark == .saved ? Theme.transferPositive : Theme.activeText
        badge.image = NSImage(systemSymbolName: e.mark.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white, tint])))
        close.isHidden = !(e.mark == .editing || e.mark == .saved)
        let service = e.provider.title
        close.toolTip = "Remove from the list (changes you save later still go to \(service) while it’s open)"
        let want = EditActivityAction.actions(for: e.mark)
        if want != shownButtons || shownService != service {
            shownButtons = want
            shownService = service
            buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for w in want {
                let label = w.title(service: service), tip = w.help(service: service)
                let b = ClosureButton(title: label) { [weak self] _ in self?.run(w) }
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.toolTip = tip
                b.setAccessibilityLabel(tip)
                buttons.addArrangedSubview(b)
            }
        }
        needsLayout = true
        needsDisplay = true
        setAccessibilityLabel(e.title + ". " + e.detail)
    }

    private func run(_ action: EditActivityAction) {
        guard let e = entry else { return }
        let editing = CloudEditing.shared
        switch action {
        case .keepBoth: editing.keepBoth(e.id)
        case .openBoth: editing.openBoth(e.id)
        case .replace: editing.replaceWithMine(e.id)
        case .send: editing.save(e.id)
        case .show: (NSApp.delegate as? AppDelegate)?.newWindow(at: e.folder)
        }
    }

    @objc private func dismiss() {
        guard let e = entry else { return }
        CloudEditing.shared.dismiss(e.id)
    }
}

enum ActivityRowStyle {
    static func background(alternate: Bool) -> NSColor { alternate ? Theme.viewAlternate : Theme.viewBackground }
    static func title(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: Tokens.FontSize.body), .foregroundColor: Theme.viewText])
        if let range = ActivityPresentation.quotedRange(in: text) {
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: Tokens.FontSize.body, weight: .medium), range: range)
        }
        return result
    }
}
