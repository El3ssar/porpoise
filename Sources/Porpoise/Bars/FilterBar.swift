import AppKit
import PorpoiseCore
import PorpoiseServices

protocol FilterBarDelegate: AnyObject {
    func filterBar(_ bar: FilterBar, changed filter: NameFilter)
    func filterBarClosed(_ bar: FilterBar)
}

/// Dolphin's filter bar (Ctrl+I / "/"): lock, text, mode, match case, close.
final class FilterBar: NSView, NSSearchFieldDelegate {
    weak var delegate: FilterBarDelegate?
    let field = NSSearchField()
    private let lockButton = FlatButton(icon: "object-unlocked", tooltip: "Keep Filter When Changing Folders")
    private let modeButton = FlatButton(icon: nil, title: FilterMode.plainText.title)
    private let caseButton = FlatButton(icon: "format-text-case", tooltip: "Match Case") // falls back to text
    private let closeButton = FlatButton(icon: "dialog-close", tooltip: "Hide Filter Bar")
    private let invalidLabel = NSTextField(labelWithString: "Invalid expression")
    var isLocked = false { didSet { lockButton.iconName = isLocked ? "object-locked" : "object-unlocked"; lockButton.isToggled = isLocked } }
    private(set) var filter = NameFilter()

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Filter…"
        field.font = Theme.font
        field.delegate = self
        field.sendsSearchStringImmediately = true
        // The field's clear (x) button changes the text without a text-did-change notification; its action catches it.
        field.target = self
        field.action = #selector(fieldAction)
        field.focusRingType = .exterior
        field.appearance = NSAppearance(named: .darkAqua)
        lockButton.onClick = { [weak self] in self?.isLocked.toggle() }
        modeButton.showsMenuIndicator = true
        modeButton.isSplitButton = true
        modeButton.menuProvider = { [weak self] in self?.modeMenu() }
        if !IconTheme.shared.has("format-text-case") { caseButton.iconName = nil; caseButton.title = "Aa" }
        caseButton.onClick = { [weak self] in
            guard let self else { return }
            self.caseButton.isToggled.toggle()
            self.filter.caseSensitive = self.caseButton.isToggled
            self.notify()
        }
        closeButton.onClick = { [weak self] in self.map { $0.delegate?.filterBarClosed($0) } }
        invalidLabel.textColor = Theme.negativeText
        invalidLabel.font = Theme.font
        invalidLabel.isHidden = true
        for v in [lockButton, field, invalidLabel, modeButton, caseButton, closeButton] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height
        lockButton.frame = CGRect(x: 6, y: (h - 28) / 2, width: 28, height: 28)
        closeButton.frame = CGRect(x: bounds.width - 34, y: (h - 28) / 2, width: 28, height: 28)
        caseButton.frame = CGRect(x: closeButton.frame.minX - 34, y: (h - 28) / 2, width: 30, height: 28)
        let mw = modeButton.intrinsicContentSize.width
        modeButton.frame = CGRect(x: caseButton.frame.minX - mw - 6, y: (h - 28) / 2, width: mw, height: 28)
        let iw: CGFloat = invalidLabel.isHidden ? 0 : 130
        invalidLabel.frame = CGRect(x: modeButton.frame.minX - iw - 4, y: (h - 18) / 2, width: iw, height: 18)
        field.frame = CGRect(x: 40, y: (h - 24) / 2, width: modeButton.frame.minX - 46 - iw, height: 24)
    }

    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill(); bounds.fill()
        let l = NSBezierPath(); l.move(to: CGPoint(x: 0, y: 0.5)); l.line(to: CGPoint(x: bounds.width, y: 0.5))
        Theme.separator.setStroke(); l.stroke()
    }

    private func modeMenu() -> NSMenu {
        let m = NSMenu()
        for mode in FilterMode.allCases {
            let it = m.addItem(withTitle: mode.title, action: #selector(setMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = filter.mode == mode ? .on : .off
        }
        return m
    }

    @objc private func setMode(_ s: NSMenuItem) {
        filter.mode = FilterMode(rawValue: s.representedObject as? String ?? "") ?? .plainText
        modeButton.title = filter.mode.title
        needsLayout = true
        notify()
    }

    func controlTextDidChange(_ obj: Notification) {
        filter.text = field.stringValue
        notify()
    }

    @objc private func fieldAction() {
        guard field.stringValue != filter.text else { return }
        filter.text = field.stringValue
        notify()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if field.stringValue.isEmpty { delegate?.filterBarClosed(self) } else { field.stringValue = ""; filter.text = ""; notify() }
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.moveDown(_:)) {
            window?.makeFirstResponder(nil)
            NotificationCenter.default.post(name: .focusView, object: window)
            return true
        }
        return false
    }

    private func notify() {
        let valid = filter.matcher() != nil
        invalidLabel.isHidden = valid
        needsLayout = true
        if valid { delegate?.filterBar(self, changed: filter) }
    }

    func clear() {
        field.stringValue = ""
        filter.text = ""
        notify()
    }

    func focus() { window?.makeFirstResponder(field) }
}

extension Notification.Name {
    static let focusView = Notification.Name("PorpoiseFocusView")
}
