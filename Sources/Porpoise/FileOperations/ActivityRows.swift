import AppKit
import PorpoiseCore
import PorpoiseServices

/// One job in the Activity list: what it does, how far it is, and what can be done to it.
final class ActivityRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let statusBadge = NSImageView()
    private let icon = NSImageView()
    private let bar = ThinProgressView()
    private let buttons = NSStackView()
    private weak var activity: Activity?
    private weak var parentWindow: NSWindow?
    private var shownButtons: [ActivityAction] = []
    private var tracking: NSTrackingArea?
    private var hovered = false
    private let alternate: Bool

    override var isFlipped: Bool { true }

    init(window: NSWindow?, alternate: Bool) {
        parentWindow = window
        self.alternate = alternate
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        buttons.spacing = 8
        icon.imageScaling = .scaleProportionallyDown
        for v in [icon, title, statusBadge, status, bar, buttons] as [NSView] { addSubview(v) }
        Theme.whenChanged(self) { [weak self] in
            guard let self, let activity = self.activity else { return }
            self.update(activity)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 16, y: 10, width: 32, height: 32)
        let actionWidth = CGFloat(shownButtons.count * 24 + max(0, shownButtons.count - 1) * 8)
        buttons.frame = CGRect(x: bounds.width - 12 - actionWidth, y: 14, width: actionWidth, height: 24)
        let textWidth = max(0, buttons.frame.minX - 12 - 60)
        title.frame = CGRect(x: 60, y: 9, width: textWidth, height: 17)
        let progressWidth = min(72, max(32, textWidth * 0.24))
        bar.frame = CGRect(x: 60, y: 34, width: progressWidth, height: 4)
        statusBadge.frame = CGRect(x: 60, y: 29, width: 12, height: 12)
        let statusX: CGFloat = !statusBadge.isHidden ? 76 : bar.isHidden ? 60 : 60 + progressWidth + 8
        status.frame = CGRect(x: statusX, y: 28, width: max(0, 60 + textWidth - statusX), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        ActivityRowStyle.background(alternate: alternate).setFill()
        bounds.fill()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateReveal() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateReveal() }

    private func updateReveal() {
        buttons.alphaValue = shownButtons == [.reveal] && !hovered ? 0 : 1
    }

    func update(_ a: Activity) {
        if activity?.id != a.id {
            if let source = a.sources.first, source.isFileURL {
                icon.image = NSWorkspace.shared.icon(forFile: source.path)
            } else {
                icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "File operation")
            }
        }
        activity = a
        icon.contentTintColor = nil
        let presentation = ActivityPresentation(a)
        title.attributedStringValue = ActivityRowStyle.title(presentation.title)
        let text = presentation.detailLine
        let failed = presentation.hasFailures
        let statusText = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: failed ? Theme.transferDanger : Theme.viewTextInactive])
        if a.state == .completed && !failed {
            statusText.addAttribute(.foregroundColor, value: Theme.transferPositive, range: NSRange(location: 0, length: min(6, text.utf16.count)))
        }
        status.attributedStringValue = statusText
        statusBadge.isHidden = !failed
        if failed {
            statusBadge.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Failed")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, Theme.transferDanger]))
        }
        status.toolTip = ([presentation.detailLine] + a.errors.prefix(10)).joined(separator: "\n")
        title.toolTip = a.title
        bar.isHidden = !presentation.showsProgress
        bar.alphaValue = presentation.isPaused ? 0.4 : 1
        bar.fraction = presentation.fraction
        bar.isIndeterminate = presentation.isIndeterminate
        setButtons(presentation.actions)
        updateReveal()
        needsLayout = true
        needsDisplay = true
        setAccessibilityLabel(a.title + ". " + text)
    }

    /// The buttons that fit its state, rebuilt only when that set changes.
    private func setButtons(_ want: [ActivityAction]) {
        guard want != shownButtons else { return }
        shownButtons = want
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let c = FileOperationsController.shared
        for w in want {
            let symbol = w.symbol, tip = w.help
            let b = ClosureButton(title: "") { [weak self] _ in
                guard let a = self?.activity else { return }
                switch w {
                case .pause: c.pause(a)
                case .resume: c.resume(a)
                case .cancel: c.cancel(a)
                case .earlier: c.move(a, by: -1)
                case .later: c.move(a, by: 1)
                case .failures: c.ui?.showTransferErrors(a, window: self?.parentWindow)
                case .retry: c.retry(a, window: self?.parentWindow)
                case .reveal: if let d = a.destination { (NSApp.delegate as? AppDelegate)?.newWindow(at: d) }
                }
            }
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            b.contentTintColor = Theme.windowTextInactive
            b.imagePosition = .imageOnly
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            buttons.addArrangedSubview(b)
        }
    }
}

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
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyDown
        buttons.spacing = 8
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
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.viewText])
        if let range = ActivityPresentation.quotedRange(in: text) {
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .medium), range: range)
        }
        return result
    }
}
