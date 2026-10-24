import AppKit
import PorpoiseCore
import PorpoiseServices

extension ToolbarCommand {
    var symbol: String {
        switch self {
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .up: return "chevron.up"
        case .viewMode: return "square.grid.2x2"
        case .location: return "folder"
        case .split: return "rectangle.split.2x1"
        case .search: return "magnifyingglass"
        case .menu: return "line.3.horizontal"
        case .reload: return "arrow.clockwise"
        case .newTab: return "plus"
        case .terminal: return "terminal"
        case .commandPalette: return "command"
        case .link: return "link"
        case .customTools: return "hammer"
        case .share: return "square.and.arrow.up"
        case .airDrop: return "airdrop"
        }
    }
    var toolbarIdentifier: NSToolbarItem.Identifier { .init("Porpoise.toolbar." + rawValue) }
    static func from(_ identifier: NSToolbarItem.Identifier) -> Self? {
        Self(rawValue: identifier.rawValue.replacingOccurrences(of: "Porpoise.toolbar.", with: ""))
    }
}

/// Native customization edits the action layout; main windows keep their split-aligned breadcrumb implementation.
final class ToolbarCustomizationWindow: SecondaryWindowController, NSToolbarDelegate, NSWindowDelegate {
    private static var current: ToolbarCustomizationWindow? { openWindows().last }
    private let toolbar = NSToolbar(identifier: "PorpoiseCustomizableActions")
    private var settingsObserver: NSObjectProtocol?
    private var observation: NSKeyValueObservation?
    private var ready = false
    private let status = NSTextField(
        wrappingLabelWithString:
            "Add, remove and reorder actions using the macOS customization palette. Changes preview in all open Porpoise windows. The Location field stays available."
    )
    static func show() {
        if let current { current.showWindow(nil); current.window?.makeKeyAndOrderFront(nil); current.toolbar.runCustomizationPalette(nil); return }
        let controller = ToolbarCustomizationWindow()
        controller.present()
        controller.toolbar.runCustomizationPalette(nil)
    }
    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 180), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Customize Toolbar"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        toolbar.delegate = self; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = false
        toolbar.allowsDisplayModeCustomization = false; toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar; toolbar.itemIdentifiers = Settings.shared.toolbarCommands.map(\.toolbarIdentifier)
        let reset = ClosureButton(title: "Restore Default Toolbar") { [weak self] _ in
            self?.toolbar.itemIdentifiers = ToolbarCommand.defaults.map(\.toolbarIdentifier); self?.persist()
        }
        let customize = ClosureButton(title: "Customize…") { [weak self] _ in self?.toolbar.runCustomizationPalette(nil) }
        contentStack(
            NSStackView(views: [status, NSStackView(views: [customize, reset])]), insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24),
            spacing: 18, pinBottom: false)
        ready = true
        observation = toolbar.observe(\.itemIdentifiers, options: [.new]) { [weak self] _, _ in self?.schedulePersist() }
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object == nil || note.object as? String == "toolbarCommands" else { return }
            let identifiers = Settings.shared.toolbarCommands.map(\.toolbarIdentifier)
            if self.toolbar.itemIdentifiers != identifiers { self.toolbar.itemIdentifiers = identifiers }
        }
        window.center()
    }
    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }
    required init?(coder: NSCoder) { fatalError() }
    private func schedulePersist() { guard ready else { return }; DispatchQueue.main.async { [weak self] in self?.persist() } }
    private func persist() {
        guard ready else { return }
        var commands = toolbar.itemIdentifiers.compactMap(ToolbarCommand.from)
        if !commands.contains(.location) {
            commands.insert(.location, at: min(4, commands.count)); toolbar.itemIdentifiers = commands.map(\.toolbarIdentifier)
        }
        if commands != Settings.shared.toolbarCommands { Settings.shared.toolbarCommands = commands }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ToolbarCommand.defaults.map(\.toolbarIdentifier) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ToolbarCommand.allCases.map(\.toolbarIdentifier) }
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> { [.init("Porpoise.toolbar.location")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool)
        -> NSToolbarItem?
    {
        guard let command = ToolbarCommand.from(identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier); item.label = command.title; item.paletteLabel = command.title
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title)
        item.target = self; item.action = #selector(preview(_:))
        return item
    }
    @objc private func preview(_ sender: NSToolbarItem) {
        status.stringValue = "\(sender.label) is a toolbar preview. Drag actions in the customization palette to change the main window's toolbar."
    }
    func toolbarWillAddItem(_ notification: Notification) { schedulePersist() }
    func toolbarDidRemoveItem(_ notification: Notification) { schedulePersist() }
    func windowWillClose(_ notification: Notification) { persist() }
}
