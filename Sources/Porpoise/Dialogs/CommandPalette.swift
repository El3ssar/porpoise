import AppKit
import PorpoiseCore
import PorpoiseServices

/// The type scale, shortened for the text styles in this file.
private typealias FontSize = Tokens.FontSize

private final class PaletteTable: NSTableView {
    var invoke: (() -> Void)?
    var cancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { invoke?() } else if event.keyCode == 53 { cancel?() } else { super.keyDown(with: event) }
    }
}

/// Menu items retain their real targets, tags and represented objects. Execution restores the originating responder.
final class CommandPalette: SecondaryWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static var current: CommandPalette?
    private struct Entry { let candidate: CommandCandidate; let shortcut: String; let run: () -> Void }
    private weak var origin: MainWindowController?
    private weak var originalResponder: NSResponder?
    private var entries: [String: Entry] = [:]
    private var matches: [CommandMatch] = []
    private let field = NSSearchField()
    private let table = PaletteTable()
    private var shortcutsObserver: NSObjectProtocol?
    private let status = NSTextField(labelWithString: "↑↓ select · Return runs · Escape closes")

    static func show(owner: MainWindowController?) {
        if let current { current.dismiss(); return }
        let palette = CommandPalette(owner: owner); current = palette
        palette.showWindow(nil); palette.window?.makeKeyAndOrderFront(nil); palette.window?.makeFirstResponder(palette.field)
    }
    init(owner: MainWindowController?) {
        self.origin = owner; originalResponder = owner?.window?.firstResponder
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 740, height: 480), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
            defer: false)
        panel.title = "Command Palette"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        super.init(window: panel); panel.delegate = self
        // A floating palette, not a window: Spotlight's tighter 16-pt sides; the top clears the hidden title bar.
        let stack = contentStack(insets: NSEdgeInsets(top: Tokens.Space.xxxl, left: Tokens.Space.l, bottom: Tokens.Space.l, right: Tokens.Space.l))
        func add(_ view: NSView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        field.placeholderString = "Search commands, places, workspaces, recent folders and tabs…"
        field.font = .systemFont(ofSize: FontSize.title2); field.delegate = self;
        add(field)
        for (id, width) in [("command", 560.0), ("shortcut", 120.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.width = width; table.addTableColumn(column)
        }
        table.headerView = nil; table.rowHeight = 46; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(invoke)
        table.invoke = { [weak self] in self?.invoke() }; table.cancel = { [weak self] in self?.dismiss() }
        table.setAccessibilityLabel("Command palette results")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true; add(scroll)
        status.font = .systemFont(ofSize: FontSize.small); status.textColor = Theme.viewTextInactive; add(status)
        collect(); update()
        shortcutsObserver = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
            guard note.object == nil || ["shortcutKeySet", "keyboardShortcuts", "customTools"].contains(note.object as? String ?? "") else { return }
            DispatchQueue.main.async {
                self?.collect(); self?.update()
            }
        }
        if let frame = owner?.window?.frame {
            panel.setFrameOrigin(CGPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 80))
        } else {
            panel.center()
        }
        Theme.whenChanged(self) { [weak self] in
            self?.window?.backgroundColor = Theme.windowBackground.usingColorSpace(.sRGB) ?? Theme.windowBackground
            self?.table.backgroundColor = Theme.viewBackground
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let shortcutsObserver { NotificationCenter.default.removeObserver(shortcutsObserver) } }
    private func collect() {
        entries.removeAll()
        let owner = origin
        let registry = MenuCommandRegistry.shared; registry.refresh()
        for command in registry.commands where !command.item.isHidden {
            let item = command.item
            let shortcut = registry.shortcut(for: command.id).display
            let candidate = CommandCandidate(
                id: "action:" + command.id, title: item.title, subtitle: command.path, keywords: "command action",
                enabled: MenuCommandRegistry.enabled(item))
            entries[candidate.id] = Entry(candidate: candidate, shortcut: shortcut) {
                guard let selector = item.action, MenuCommandRegistry.enabled(item) else { return }
                NSApp.sendAction(selector, to: item.target, from: item)
            }
        }
        let tools = Settings.shared.customTools.filter { $0.placements.contains(.commandPalette) }
        if let owner, !tools.isEmpty {
            for (index, tool) in tools.enumerated() {
                let reason = owner.customToolAvailability.reason(
                    for: tool, in: owner,
                    updated: index == 0
                        ? { [weak self] in
                            self?.collect(); self?.update()
                        } : nil)
                let candidate = CommandCandidate(
                    id: "tool:" + tool.id.uuidString, title: tool.name, subtitle: "Custom tool", keywords: "tool command",
                    enabled: reason == nil)
                entries[candidate.id] = Entry(candidate: candidate, shortcut: tool.shortcut.display) { [weak owner] in owner?.executeCustomTool(tool)
                }
            }
        }
        func location(_ url: URL, title: String, category: String, id: String) {
            let candidate = CommandCandidate(id: id, title: title, subtitle: category + " · " + LocationNaming.address(for: url), keywords: category)
            entries[id] = Entry(candidate: candidate, shortcut: "") { [weak owner] in
                if let owner {
                    owner.view.setURL(url); owner.window?.makeFirstResponder(owner.view.list)
                } else {
                    AppDelegate.shared.newWindow(urls: [url])
                }
            }
        }
        for place in PlacesModel.shared.allEntries where !place.hidden {
            location(
                place.url, title: place.title, category: place.section == .remote ? "Connection" : "Place / bookmark",
                id: "place:" + place.url.absoluteString + ":" + place.title)
        }
        for workspace in Settings.shared.workspaces {
            let tabs = workspace.layout.tabs.count
            let id = "workspace:" + workspace.id.uuidString
            let candidate = CommandCandidate(
                id: id, title: workspace.name, subtitle: "Workspace · " + (tabs == 1 ? "1 tab" : "\(tabs) tabs"), keywords: "workspace layout")
            entries[id] = Entry(candidate: candidate, shortcut: "") { [weak owner] in
                if let owner {
                    owner.open(workspace)
                } else {
                    AppDelegate.shared.newWindow(at: Settings.shared.homeURL)
                    AppDelegate.shared.windows.last?.open(workspace)
                }
            }
        }
        for (index, url) in RecentLocations.shared.urls.enumerated() {
            location(
                url, title: LocationNaming.title(for: url), category: "Recent location",
                id: "recent:\(index):" + url.absoluteString)
        }
        var connections: Set<URL> = []
        for controller in AppDelegate.shared.windows {
            for tab in controller.tabs {
                let id = "tab:" + String(describing: ObjectIdentifier(tab))
                let candidate = CommandCandidate(
                    id: id, title: tab.title, subtitle: "Open tab · " + LocationNaming.address(for: tab.active.url), keywords: "tab switch window")
                entries[id] = Entry(candidate: candidate, shortcut: "") { [weak controller, weak tab] in
                    guard let controller, let tab, let index = controller.tabs.firstIndex(where: { $0 === tab }) else { return }
                    controller.window?.makeKeyAndOrderFront(nil); controller.showTab(index)
                }
                for container in tab.containers {
                    for url in container.history.entries where LocationKind.of(url).isRemote { connections.insert(url) }
                }
            }
        }
        for url in connections {
            location(url, title: LocationNaming.connectionTitle(for: url), category: "Connection", id: "connection:" + url.absoluteString)
        }
    }
    private func update() {
        matches = CommandSearch.rank(field.stringValue, candidates: entries.values.map(\.candidate), limit: entries.count)
        table.reloadData(); if !matches.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        status.stringValue =
            matches.isEmpty ? "No matching commands or locations." : "\(matches.count) results · ↑↓ select · Return runs · Escape closes"
    }
    func controlTextDidChange(_ obj: Notification) { update() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !matches.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let index = min(matches.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index); return true
        case #selector(NSResponder.insertNewline(_:)): invoke(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
    @objc private func invoke() {
        guard let match = matches[safe: table.selectedRow], let entry = entries[match.candidate.id] else { return }
        guard entry.candidate.enabled else { status.stringValue = "This action is unavailable in the current view."; return }
        let owner = origin, responder = originalResponder, action = entry.run
        dismiss()
        DispatchQueue.main.async {
            owner?.window?.makeKeyAndOrderFront(nil)
            if let responder { owner?.window?.makeFirstResponder(responder) }
            action()
        }
    }
    private func dismiss() { Self.current = nil; window?.orderOut(nil); window?.close() }
    func windowWillClose(_ notification: Notification) { if Self.current === self { Self.current = nil } }
    func windowDidResignKey(_ notification: Notification) { if Self.current === self { dismiss() } }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let match = matches[safe: row] else { return nil }
        let candidate = match.candidate
        if tableColumn?.identifier.rawValue == "shortcut" {
            let label = NSTextField(labelWithString: entries[candidate.id]?.shortcut ?? ""); label.textColor = Theme.viewTextInactive; return label
        }
        let title = NSTextField(labelWithString: candidate.title); title.font = Theme.font
        title.textColor = candidate.enabled ? Theme.viewText : Theme.viewTextInactive; title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: (candidate.enabled ? "" : "Unavailable · ") + candidate.subtitle)
        detail.font = .systemFont(ofSize: FontSize.small); detail.textColor = Theme.viewTextInactive; detail.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = Tokens.Space.xxs
        stack.setAccessibilityLabel(candidate.title + ", " + detail.stringValue); return stack
    }
}

extension AppDelegate {
    @objc func showCommandPalette(_ sender: Any?) {
        let owner = NSApp.mainWindow?.windowController as? MainWindowController ?? windows.first
        CommandPalette.show(owner: owner)
    }
    @objc func customizeToolbar(_ sender: Any?) { ToolbarCustomizationWindow.show() }
}
