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
        }
    }
    var toolbarIdentifier: NSToolbarItem.Identifier { .init("Porpoise.toolbar." + rawValue) }
    static func from(_ identifier: NSToolbarItem.Identifier) -> Self? {
        Self(rawValue: identifier.rawValue.replacingOccurrences(of: "Porpoise.toolbar.", with: ""))
    }
}

/// Native customization edits the action layout; main windows keep their split-aligned breadcrumb implementation.
final class ToolbarCustomizationWindow: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private static var current: ToolbarCustomizationWindow?
    private let toolbar = NSToolbar(identifier: "PorpoiseCustomizableActions")
    private var settingsObserver: NSObjectProtocol?
    private var observation: NSKeyValueObservation?
    private var ready = false
    private let status = NSTextField(
        wrappingLabelWithString:
            "Add, remove and reorder actions using the macOS customisation palette. Changes preview in all open Porpoise windows. The Location field stays available."
    )
    static func show() {
        if let current { current.showWindow(nil); current.window?.makeKeyAndOrderFront(nil); current.toolbar.runCustomizationPalette(nil); return }
        let controller = ToolbarCustomizationWindow(); current = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        controller.toolbar.runCustomizationPalette(nil)
    }
    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 180), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Customise Toolbar"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        toolbar.delegate = self; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = false
        toolbar.allowsDisplayModeCustomization = false; toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar; toolbar.itemIdentifiers = Settings.shared.toolbarCommands.map(\.toolbarIdentifier)
        let reset = ClosureButton(title: "Restore Default Toolbar") { [weak self] _ in
            self?.toolbar.itemIdentifiers = ToolbarCommand.defaults.map(\.toolbarIdentifier); self?.persist()
        }
        let customise = ClosureButton(title: "Customise…") { [weak self] _ in self?.toolbar.runCustomizationPalette(nil) }
        let stack = NSStackView(views: [status, NSStackView(views: [customise, reset])]); stack.orientation = .vertical; stack.alignment = .leading;
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            ])
        }
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
        status.stringValue = "\(sender.label) is a toolbar preview. Drag actions in the customisation palette to change the main window's toolbar."
    }
    func toolbarWillAddItem(_ notification: Notification) { schedulePersist() }
    func toolbarDidRemoveItem(_ notification: Notification) { schedulePersist() }
    func windowWillClose(_ notification: Notification) { persist(); Self.current = nil }
}
