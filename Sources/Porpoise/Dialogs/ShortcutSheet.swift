import AppKit
import PorpoiseCore
import PorpoiseServices

/// Help › Keyboard Shortcuts (⌘?): every shortcut in effect, from the menu bar as it is now (key set and the user's own
/// bindings), plus the keys the file list handles itself. Type to filter; Esc closes.
final class ShortcutSheet: SecondaryWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    struct Row: Equatable {
        let title: String
        let keys: String
    }
    struct Section: Equatable {
        let title: String
        let rows: [Row]
    }
    private enum Line { case header(String), row(Row) }

    private let search = NSSearchField()
    private let table = NSTableView()
    private var sections: [Section] = []
    private var lines: [Line] = []
    private var observer: NSObjectProtocol?

    static func show() {
        if let open = openWindows(ShortcutSheet.self).last { open.window?.close(); return }
        ShortcutSheet().present()
    }

    private init() {
        let window = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 620), styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 380, height: 300)
        super.init(window: window); window.delegate = self
        search.placeholderString = "Find a shortcut"; search.delegate = self
        let column = NSTableColumn(identifier: .init("action")); column.title = "Action"; column.resizingMask = .autoresizingMask
        let keys = NSTableColumn(identifier: .init("keys")); keys.title = "Keys"; keys.width = 150; keys.resizingMask = []
        table.addTableColumn(column); table.addTableColumn(keys)
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.rowHeight = 22
        table.style = .plain; table.selectionHighlightStyle = .none; table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Keyboard shortcuts")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let stack = contentStack(spacing: 10)
        for view in [search, scroll] as [NSView] {
            stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        reload()
        window.center()
        window.initialFirstResponder = search
        observer = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func reload() {
        sections = NSApp.mainMenu.map { Self.sections($0, keySet: Settings.shared.shortcutKeySet) } ?? []
        filter()
    }

    private func filter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        lines = sections.flatMap { section -> [Line] in
            let rows = query.isEmpty ? section.rows : section.rows.filter { "\(section.title) \($0.title) \($0.keys)".lowercased().contains(query) }
            return rows.isEmpty ? [] : [.header(section.title)] + rows.map(Line.row)
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    /// Esc in the search field clears it first, then closes the window.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if search.stringValue.isEmpty { window?.close() } else { search.stringValue = ""; filter() }
        return true
    }
    override func cancelOperation(_ sender: Any?) { window?.close() }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = lines[row] { return true }
        return false
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title); label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        case .row(let line):
            let isKeys = tableColumn?.identifier.rawValue == "keys"
            let label = NSTextField(labelWithString: isKeys ? line.keys : line.title)
            label.lineBreakMode = .byTruncatingTail; label.toolTip = isKeys ? line.keys : line.title
            if isKeys { label.textColor = .secondaryLabelColor }
            return label
        }
    }

    // MARK: - Content

    /// The menu bar's bound actions grouped by menu, in menu order (hidden alternates with their item), then the file
    /// list's own keys.
    static func sections(_ menu: NSMenu, keySet: ShortcutKeySet) -> [Section] {
        menuSections(menu) + [Section(title: "In the File List", rows: listKeys(keySet))]
    }

    /// Every action in `menu` that has a key, as the menu shows it now: one row per action, its keys in menu order.
    static func menuSections(_ menu: NSMenu) -> [Section] {
        menu.items.compactMap { top -> Section? in
            guard let submenu = top.submenu, submenu !== NSApp.servicesMenu else { return nil }
            var order: [String] = [], titles: [String: String] = [:], keys: [String: [String]] = [:]
            @MainActor func walk(_ menu: NSMenu, path: [String]) {
                for item in menu.items where !item.isSeparatorItem {
                    if let sub = item.submenu {
                        if sub !== NSApp.servicesMenu { walk(sub, path: path + [item.title]) }
                        continue
                    }
                    guard item.action != nil, !MenuCommandRegistry.isAppKits(item), !item.keyEquivalent.isEmpty else { continue }
                    let id = MenuCommandRegistry.id(item)
                    if keys[id] == nil { order.append(id) }
                    if !item.isHidden || titles[id] == nil { titles[id] = (path + [item.title]).joined(separator: " › ") }
                    let display = KeyboardShortcut(key: item.keyEquivalent, modifiers: ShortcutModifiers(item.keyEquivalentModifierMask)).display
                    if !(keys[id] ?? []).contains(display) { keys[id, default: []].append(display) }
                }
            }
            walk(submenu, path: [])
            let rows = order.map { Row(title: titles[$0] ?? "", keys: (keys[$0] ?? []).joined(separator: "  ")) }
            return rows.isEmpty ? nil : Section(title: top.title, rows: rows)
        }
    }

    /// Keys the file list handles itself (they aren't menu items, so they can't be rebound).
    static func listKeys(_ keySet: ShortcutKeySet) -> [Row] {
        var rows = [
            Row(title: "Move the selection", keys: "↑ ↓ ← →"), Row(title: "Extend the selection", keys: "⇧↑ ⇧↓ ⇧← ⇧→"),
            Row(title: "First or last item", keys: "Home  End"), Row(title: "Select by name", keys: "Type the name"),
        ]
        // With the Mac keys Return renames (File › Rename); with Dolphin's it opens.
        if keySet == .dolphin { rows.append(Row(title: "Open", keys: "↩")) }
        rows += [
            Row(title: "Quick Look", keys: "Space"), Row(title: "Back", keys: "⌫"), Row(title: "Filter", keys: "/"),
            Row(title: "Show Hidden Files", keys: "⌥."), Row(title: "Add or remove the current item", keys: "⌃Space"),
            Row(title: "Expand or collapse a folder (Details)", keys: "→  ←"), Row(title: "Clear the selection", keys: "Esc"),
        ]
        return rows
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

extension AppDelegate {
    /// Help › Keyboard Shortcuts (⌘?): opens the sheet, or closes it when it's open.
    @objc func showKeyboardShortcuts(_ sender: Any?) { ShortcutSheet.show() }
}
