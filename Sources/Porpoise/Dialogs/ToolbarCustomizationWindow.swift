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
        case .action: return "ellipsis.circle"
        }
    }
    var toolbarIdentifier: NSToolbarItem.Identifier { .init("Porpoise.toolbar." + rawValue) }
    static func from(_ identifier: NSToolbarItem.Identifier) -> Self? {
        Self(rawValue: identifier.rawValue.replacingOccurrences(of: "Porpoise.toolbar.", with: ""))
    }
}

/// Native customization edits the action layout; main windows keep their split-aligned breadcrumb implementation.
/// It opens as a sheet on the frontmost browser window, so it's clear which toolbar it changes; a window of its own only
/// when no browser window is open.
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
        if let current {
            if let parent = current.window?.sheetParent { parent.makeKeyAndOrderFront(nil) } else { current.present() }
            current.toolbar.runCustomizationPalette(nil)
            return
        }
        let controller = ToolbarCustomizationWindow()
        if let parent = browserWindow, let sheet = controller.window {
            controller.keepOpen()
            parent.makeKeyAndOrderFront(nil)
            parent.beginSheet(sheet)
        } else {
            controller.present()
        }
        controller.toolbar.runCustomizationPalette(nil)
    }
    /// The browser window in front that can take a sheet now.
    static var browserWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.windowController is MainWindowController && $0.isVisible && $0.attachedSheet == nil }
    }
    private init() {
        let window = EditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 150), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Customize Toolbar"; window.isReleasedWhenClosed = false
        // The heading names it; the title stays for the Window menu but isn't drawn twice.
        window.titleVisibility = .hidden
        // Labels under the items, as in the palette, so each action is named.
        window.toolbarStyle = .expanded
        super.init(window: window); window.delegate = self
        toolbar.delegate = self; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = false
        toolbar.allowsDisplayModeCustomization = false; toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar; toolbar.itemIdentifiers = Settings.shared.toolbarCommands.map(\.toolbarIdentifier)
        let reset = ClosureButton(title: "Restore Default Toolbar") { [weak self] _ in
            self?.toolbar.itemIdentifiers = Settings.shared.defaultToolbarCommands.map(\.toolbarIdentifier); self?.persist()
        }
        let customize = ClosureButton(title: "Customize…") { [weak self] _ in self?.toolbar.runCustomizationPalette(nil) }
        let done = ClosureButton(title: "Done") { [weak self] _ in self?.finish() }
        done.keyEquivalent = "\r"
        window.defaultButtonCell = done.cell as? NSButtonCell
        window.onCancel = { [weak self] in self?.finish() }
        // A sheet shows no window title: the heading says what it is.
        let heading = NSTextField(labelWithString: "Customize Toolbar")
        heading.font = .systemFont(ofSize: Tokens.FontSize.title2, weight: .semibold)
        let buttons = NSStackView(views: [reset, NSView(), customize, done])
        buttons.spacing = Tokens.Spacing.s
        let stack = contentStack(
            NSStackView(views: [heading, status, buttons]), insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20),
            spacing: Tokens.Spacing.m, pinBottom: false)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Settings.shared.defaultToolbarCommands.map(\.toolbarIdentifier)
    }
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
    /// Done (Return), or Escape: the changes are already in every window's toolbar.
    private func finish() {
        persist()
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.close()
    }
    override func cancelOperation(_ sender: Any?) { finish() }

    /// Return clicks Done and Escape finishes, whatever has the focus (the sheet holds only buttons, which take neither).
    private final class EditorWindow: NSWindow {
        var onCancel: () -> Void = {}
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: defaultButtonCell?.performClick(nil)
            case 53: onCancel()
            default: super.keyDown(with: event)
            }
        }
        override func cancelOperation(_ sender: Any?) { onCancel() }
    }
}
