import AppKit
import PorpoiseCore
import PorpoiseServices

protocol SearchBarDelegate: AnyObject {
    func searchBar(_ bar: SearchBar, search text: String, everywhere: Bool, contents: Bool)
    func searchBarClosed(_ bar: SearchBar)
}

/// Dolphin's search bar (Ctrl+F): field, Here / Everywhere, file names vs contents, close.
final class SearchBar: NSView, NSSearchFieldDelegate {
    weak var delegate: SearchBarDelegate?
    let field = NSSearchField()
    private let hereButton = FlatButton(icon: "folder", title: "Here")
    private let everywhereButton = FlatButton(icon: "system-search", title: "Everywhere")
    private let optionsButton = FlatButton(icon: "view-filter", title: "Filter")
    private let closeButton = FlatButton(icon: "dialog-close", tooltip: "Quit Searching")
    private var everywhere = false { didSet { if everywhere != oldValue { updateButtons(); fire() } } }
    private var contents = false {
        didSet {
            guard contents != oldValue else { return }
            field.placeholderString = contents ? "Search in file contents…" : "Search…"
            fire()
        }
    }
    var scopeFolder: URL? { didSet { hereButton.toolTip = "Limit the search to “\(scopeFolder?.lastPathComponent ?? "")” and its subfolders" } }
    private var debounce: Timer?
    /// Typing waits this long before searching.
    private static let debounceDelay: TimeInterval = 0.3

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Search…"
        field.font = Theme.font
        field.delegate = self
        field.focusRingType = .exterior
        field.appearance = NSAppearance(named: .darkAqua)
        field.sendsWholeSearchString = false
        hereButton.onClick = { [weak self] in self?.everywhere = false }
        everywhereButton.onClick = { [weak self] in self?.everywhere = true }
        everywhereButton.toolTip = "Search your whole home folder (Spotlight)"
        optionsButton.showsMenuIndicator = true
        optionsButton.isSplitButton = true
        optionsButton.menuProvider = { [weak self] in self?.optionsMenu() }
        closeButton.onClick = { [weak self] in self.map { $0.delegate?.searchBarClosed($0) } }
        for v in [field, hereButton, everywhereButton, optionsButton, closeButton] as [NSView] { addSubview(v) }
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func updateButtons() {
        hereButton.isToggled = !everywhere
        everywhereButton.isToggled = everywhere
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        closeButton.frame = CGRect(x: bounds.width - 34, y: (h - 28) / 2, width: 28, height: 28)
        var x = closeButton.frame.minX - 6
        for b in [optionsButton, everywhereButton, hereButton] {
            let w = b.intrinsicContentSize.width
            x -= w
            b.frame = CGRect(x: x, y: (h - 28) / 2, width: w, height: 28)
            x -= 4
        }
        field.frame = CGRect(x: 8, y: (h - 24) / 2, width: x - 14, height: 24)
    }

    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill(); bounds.fill()
        let l = NSBezierPath(); l.move(to: CGPoint(x: 0, y: bounds.height - 0.5)); l.line(to: CGPoint(x: bounds.width, y: bounds.height - 0.5))
        Theme.separator.setStroke(); l.stroke()
    }

    private func optionsMenu() -> NSMenu {
        let m = NSMenu()
        let h = m.addItem(withTitle: "Search in:", action: nil, keyEquivalent: ""); h.isEnabled = false
        let names = m.addItem(withTitle: "File Names", action: #selector(setNames), keyEquivalent: "")
        names.target = self; names.state = contents ? .off : .on
        let cont = m.addItem(withTitle: "File Contents", action: #selector(setContents), keyEquivalent: "")
        cont.target = self; cont.state = contents ? .on : .off
        return m
    }

    @objc private func setNames() { contents = false }
    @objc private func setContents() { contents = true }

    func controlTextDidChange(_ obj: Notification) {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: Self.debounceDelay, repeats: false) { [weak self] _ in self?.fire() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { debounce?.invalidate(); delegate?.searchBarClosed(self); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { fire(); NotificationCenter.default.post(name: .focusView, object: window); return true }
        return false
    }

    /// Searches now; a pending debounced search is dropped so it doesn't run the same query again.
    private func fire() {
        debounce?.invalidate()
        debounce = nil
        delegate?.searchBar(self, search: field.stringValue, everywhere: everywhere, contents: contents)
    }

    func focus() { window?.makeFirstResponder(field) }

    func clear() {
        debounce?.invalidate()
        debounce = nil
        field.stringValue = ""
    }
}
