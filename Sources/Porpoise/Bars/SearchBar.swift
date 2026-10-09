import AppKit
import PorpoiseCore

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
        field.focusRingType = .none
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

/// Runs a search: Spotlight (NSMetadataQuery) like Dolphin's Baloo search, with live results.
final class SearchRunner: NSObject {
    private let query = NSMetadataQuery()
    private let update: ([FileItem], Bool) -> Void
    private let text: String
    private let scope: URL
    private let contents: Bool
    /// Cancellation token of the running simple search.
    private var fallbackWork: DispatchWorkItem?
    /// Results already read from disk (Spotlight reports the growing list again on every progress/update).
    private var loaded: [String: FileItem] = [:]
    private var gatheringDone = false

    private static let maxSpotlightResults = 5000
    private static let maxSimpleResults = 2000
    private static let maxSimpleVisited = 200_000
    /// Larger files are not searched for contents by the simple search.
    private static let maxContentSearchSize = 5_000_000

    init(text: String, scope: URL, contents: Bool, update: @escaping ([FileItem], Bool) -> Void) {
        self.text = text
        self.scope = scope
        self.contents = contents
        self.update = update
        super.init()
    }

    func start() {
        let pattern = "*\(text)*"
        query.predicate = contents
            ? NSPredicate(format: "kMDItemTextContent LIKE[cd] %@ OR kMDItemFSName LIKE[cd] %@", pattern, pattern)
            : NSPredicate(format: "kMDItemFSName LIKE[cd] %@", pattern)
        query.searchScopes = [scope]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(progress), name: .NSMetadataQueryGatheringProgress, object: query)
        // Live results: files created, renamed or deleted while the results are shown.
        NotificationCenter.default.addObserver(self, selector: #selector(liveUpdate), name: .NSMetadataQueryDidUpdate, object: query)
        if !query.start() { simpleSearch() }
    }

    @objc private func progress() { publish(done: false) }

    @objc private func liveUpdate(_ n: Notification) {
        guard gatheringDone, fallbackWork == nil else { return }
        // Changed files are read again; the others come from the cache.
        for case let r as NSMetadataItem in (n.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [Any]) ?? [] {
            if let p = r.value(forAttribute: NSMetadataItemPathKey) as? String { loaded[p] = nil }
        }
        query.disableUpdates()
        publish(done: true)
        query.enableUpdates()
    }

    @objc private func gathered() {
        gatheringDone = true
        // Spotlight doesn't index hidden or excluded folders; Dolphin's simple search finds them. Without Spotlight
        // results it takes over (no "No items found" in between).
        if query.resultCount == 0 { simpleSearch(); return }
        query.disableUpdates()
        publish(done: true)
        query.enableUpdates()
    }

    private func publish(done: Bool) {
        var items: [FileItem] = []
        var seen: [String: FileItem] = [:]
        for i in 0..<min(query.resultCount, Self.maxSpotlightResults) {
            guard let r = query.result(at: i) as? NSMetadataItem, let p = r.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            // Each path is read from disk once (Spotlight reports the whole growing list every time).
            guard let it = loaded[p] ?? FileItem.load(URL(fileURLWithPath: p)) else { continue }
            seen[p] = it
            items.append(it)
        }
        loaded = seen
        update(items, done)
    }

    /// Dolphin's "Simple search" (filenamesearch:/): walks the folder tree.
    private func simpleSearch() {
        let needle = text.lowercased()
        let scope = scope
        let contents = contents
        fallbackWork?.cancel()
        let work = DispatchWorkItem {}
        fallbackWork = work
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var out: [FileItem] = []
            let e = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
            var n = 0
            while let u = e?.nextObject() as? URL {
                if work.isCancelled { return }
                n += 1
                if n > Self.maxSimpleVisited { break }
                var hit = u.lastPathComponent.lowercased().contains(needle)
                if !hit && contents, let d = try? Data(contentsOf: u, options: .mappedIfSafe), d.count < Self.maxContentSearchSize,
                   let s = String(data: d, encoding: .utf8) { hit = s.lowercased().contains(needle) }
                if hit, let it = FileItem.load(u) { out.append(it) }
                if out.count >= Self.maxSimpleResults { break }
            }
            DispatchQueue.main.async { if !work.isCancelled { self?.update(out, true) } }
        }
    }

    func stop() {
        query.stop()
        fallbackWork?.cancel()
        loaded = [:]
        NotificationCenter.default.removeObserver(self)
    }
}

/// "Recent Files": Spotlight's last-used dates (the Mac's equivalent of recentlyused:/files).
final class RecentFilesQuery: NSObject {
    private let query = NSMetadataQuery()
    private let done: ([FileItem]) -> Void
    private static let maxAge: TimeInterval = 30 * 86400
    private static let maxResults = 200

    init(done: @escaping ([FileItem]) -> Void) {
        self.done = done
        super.init()
        let since = Date().addingTimeInterval(-Self.maxAge)
        query.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@ AND kMDItemContentTypeTree != 'public.folder'", since as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
    }

    @objc private func gathered() {
        query.stop()
        var items: [FileItem] = []
        for i in 0..<min(query.resultCount, Self.maxResults) {
            guard let r = query.result(at: i) as? NSMetadataItem, let p = r.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !p.contains("/Library/"), let it = FileItem.load(URL(fileURLWithPath: p)) else { continue }
            items.append(it)
        }
        done(items)
        NotificationCenter.default.removeObserver(self)
    }
}
