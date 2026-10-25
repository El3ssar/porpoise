import AppKit

/// A utility window's real toolbar (DESIGN-CONTRACT §6.6): symbol buttons with labels, and controls such as a pop-up,
/// in the window's title bar instead of a row of bordered buttons in its content. Each button is enabled only while it
/// can act; `validate()` re-checks them after the window's state changes.
final class UtilityToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    enum Item {
        /// A labelled symbol button: what it does, and whether it can now.
        case button(id: String, label: String, symbol: String, enabled: () -> Bool = { true }, action: () -> Void)
        /// A control (a pop-up) with its label.
        case control(id: String, label: String, view: NSView)
        case space
        case flexibleSpace

        var identifier: NSToolbarItem.Identifier {
            switch self {
            case .button(let id, _, _, _, _), .control(let id, _, _): NSToolbarItem.Identifier(id)
            case .space: .space
            case .flexibleSpace: .flexibleSpace
            }
        }
    }

    let toolbar: NSToolbar
    private let items: [Item]

    /// Puts the toolbar on `window`, its title shown beside the items.
    @discardableResult
    static func install(_ items: [Item], on window: NSWindow, name: String) -> UtilityToolbar {
        let bar = UtilityToolbar(items, name: name)
        window.toolbar = bar.toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        // The toolbar keeps a weak delegate: the window keeps this one.
        objc_setAssociatedObject(window, &UtilityToolbar.key, bar, .OBJC_ASSOCIATION_RETAIN)
        return bar
    }

    private static var key = 0

    init(_ items: [Item], name: String) {
        self.items = items
        toolbar = NSToolbar(identifier: name)
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    /// Re-checks which buttons can act now.
    func validate() { toolbar.validateVisibleItems() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { items.map(\.identifier) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { items.map(\.identifier) }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        for item in items where item.identifier == identifier {
            switch item {
            case .button(_, let label, let symbol, _, _):
                let t = NSToolbarItem(itemIdentifier: identifier)
                t.label = label
                t.toolTip = label
                t.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                t.isBordered = true
                t.target = self
                t.action = #selector(run(_:))
                return t
            case .control(_, let label, let view):
                let t = NSToolbarItem(itemIdentifier: identifier)
                t.label = label
                t.toolTip = label
                t.view = view
                view.setAccessibilityLabel(label)
                return t
            case .space, .flexibleSpace:
                return nil
            }
        }
        return nil
    }

    @objc private func run(_ sender: NSToolbarItem) {
        for case .button(let id, _, _, let enabled, let action) in items where id == sender.itemIdentifier.rawValue && enabled() { action() }
        validate()
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        for case .button(let id, _, _, let enabled, _) in items where id == item.itemIdentifier.rawValue { return enabled() }
        return true
    }

    /// The toolbar item for `id` (tests, the bridge).
    func item(_ id: String) -> NSToolbarItem? { toolbar.items.first { $0.itemIdentifier.rawValue == id } }

    /// Runs the button `id` as a click would, if it can act.
    func perform(_ id: String) {
        guard let item = item(id), validateToolbarItem(item) else { return }
        run(item)
    }
}
