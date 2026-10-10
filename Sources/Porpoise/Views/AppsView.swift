import AppKit
import PorpoiseCore
import PorpoiseServices

/// What the app library asks of its view container (selection, opening, menus and Quick Look go the usual way,
/// so every menu command and shortcut works on the selected apps).
protocol AppsViewHost: AnyObject {
    func appsViewDidBecomeActive(_ v: AppsView)
    func appsView(_ v: AppsView, open items: [FileItem])
    func appsView(_ v: AppsView, menuFor item: FileItem?) -> NSMenu?
    func appsViewQuickLook(_ v: AppsView)
    func appsView(_ v: AppsView, hovered item: FileItem?)
}

/// The Applications folder as an app library: a glass search field over a theme-coloured backdrop and a
/// Launchpad-like grid of big icons. Typing anywhere searches.
final class AppsView: NSView, NSTextFieldDelegate {
    weak var host: AppsViewHost?
    let model: DirectoryModel
    let grid: AppsGridView
    private let backdrop = AppsBackdrop()
    private let scroll = NSScrollView()
    private let searchGlass = GlassGroup(cornerRadius: 19)
    let field = NSTextField()
    private let magnifier = NSImageView()
    private let clearButton = NSButton()
    private let noResults = NSTextField(labelWithString: "No Results")

    /// The search changed the filter: the reload that follows (from the model) animates.
    private var animateNextReload = false

    private static let searchHeight: CGFloat = 38
    private static let searchTop: CGFloat = 26

    init(model: DirectoryModel) {
        self.model = model
        grid = AppsGridView(model: model)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        addSubview(backdrop)

        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        // The grid scrolls under the glass search field.
        scroll.contentInsets = NSEdgeInsets(top: Self.searchTop + Self.searchHeight + 22, left: 0, bottom: 24, right: 0)
        addSubview(scroll)
        grid.owner = self

        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        magnifier.contentTintColor = Theme.viewTextInactive
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = Theme.viewText
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .foregroundColor: Theme.viewTextInactive, .font: NSFont.systemFont(ofSize: 15),
        ])
        field.delegate = self
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        clearButton.isBordered = false
        clearButton.contentTintColor = Theme.viewTextInactive
        clearButton.target = self
        clearButton.action = #selector(clearSearch)
        clearButton.isHidden = true
        for v in [magnifier, field, clearButton] as [NSView] { searchGlass.content.addSubview(v) }
        addSubview(searchGlass)

        noResults.font = .systemFont(ofSize: 22, weight: .medium)
        noResults.textColor = Theme.viewTextInactive
        noResults.isHidden = true
        addSubview(noResults)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        scroll.frame = bounds
        let w = min(460, bounds.width - 64)
        searchGlass.frame = CGRect(x: (bounds.width - w) / 2, y: Self.searchTop, width: w, height: Self.searchHeight)
        let h = Self.searchHeight
        magnifier.frame = CGRect(x: 14, y: (h - 18) / 2, width: 18, height: 18)
        clearButton.frame = CGRect(x: w - 32, y: (h - 18) / 2, width: 18, height: 18)
        let fh = ceil(field.intrinsicContentSize.height)
        field.frame = CGRect(x: 40, y: (h - fh) / 2, width: w - 40 - 38, height: fh)
        grid.updateLayout(width: scroll.contentSize.width)
        noResults.sizeToFit()
        noResults.frame.origin = CGPoint(x: (bounds.width - noResults.frame.width) / 2, y: bounds.height * 0.42)
    }

    /// The apps changed (loaded, filtered, one installed or removed). `animated`: the grid moves to the result.
    func reload(animated: Bool = false) {
        let animate = animated || animateNextReload
        animateNextReload = false
        grid.updateLayout(width: scroll.contentSize.width, animated: animate)
        grid.needsDisplay = true
        noResults.isHidden = !(model.rows.isEmpty && !field.stringValue.isEmpty)
    }

    /// Shown again (entered Applications): fresh search, top of the grid.
    func prepareForDisplay() {
        // The container has reset the model's filter; the field follows.
        field.stringValue = ""
        clearButton.isHidden = true
        scroll.contentView.scroll(to: CGPoint(x: 0, y: -scroll.contentInsets.top))
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) { searchChanged() }

    private func searchChanged() {
        clearButton.isHidden = field.stringValue.isEmpty
        let filter = NameFilter(text: field.stringValue)
        animateNextReload = filter != model.filter
        model.filter = filter
        // The first match is ready for Return.
        if let first = model.rows.first, !field.stringValue.isEmpty {
            model.selection = [first.item.url]
            model.currentURL = first.item.url
        }
        grid.scrollToCurrent()
        reload()
    }

    @objc private func clearSearch() {
        field.stringValue = ""
        searchChanged()
        window?.makeFirstResponder(grid)
    }

    /// Typing in the grid goes to the search field (as in Launchpad).
    func startSearch(with text: String) {
        window?.makeFirstResponder(field)
        field.currentEditor()?.insertText(text)
    }

    /// Return opens the first match, Escape clears, Down moves into the grid.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let items = model.selectedItems
            if !items.isEmpty { host?.appsView(self, open: items) }
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { window?.makeFirstResponder(grid) } else { clearSearch() }
        case #selector(NSResponder.moveDown(_:)):
            window?.makeFirstResponder(grid)
        default:
            return false
        }
        return true
    }
}
