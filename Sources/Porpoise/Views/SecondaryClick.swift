import AppKit

/// Secondary clicks must finish before any primary-click selection, disclosure, download or open handling.
enum SecondaryClick {
    static func matches(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown || event.type == .rightMouseUp
            || (event.modifierFlags.contains(.control) && (event.type == .leftMouseDown || event.type == .leftMouseUp))
    }

    #if PORPOISE_TEST_HOOKS
    /// Records the actual menu at the presentation boundary without entering AppKit's modal tracking loop.
    static var presentForTesting: ((NSMenu, NSEvent, NSView) -> Void)?
    #endif

    static func present(_ event: NSEvent, in view: NSView) {
        guard let menu = view.menu(for: event) else { return }
        #if PORPOISE_TEST_HOOKS
        if let presentForTesting { presentForTesting(menu, event, view); return }
        #endif
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}
