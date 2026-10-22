import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Tab order and focus

extension MainWindowController {
    /// The window's Tab order, as it reads: the sidebar (Places, Folders, Shelf), the toolbar with the location, the
    /// tab bar, each pane (its bars, the list, the status bar's zoom), the Information panel, then the terminal.
    /// What takes focus depends on Full Keyboard Access (custom buttons and the path only with it on, as on any Mac);
    /// hidden panels and bars are left out. `DolphinWindow` walks it for Tab and ⇧Tab: AppKit's own loop covers the
    /// content view only, not the title bar, and goes stale as panels come and go.
    var keyLoop: [NSView] {
        let panes: [NSView] = [tab.primary, tab.secondary].compactMap { $0 }
        let sections: [NSView?] =
            [leftStack, toolbar, tabBar] + panes + [showInformation ? information : nil, showTerminal ? terminal : nil]
        return sections.compactMap { $0 }.flatMap { Self.keyViews(in: $0) }
    }

    /// The views in `root` that take focus, top to bottom and left to right. A view that takes focus is one stop: what's
    /// inside it (a list's cells, an outline's rows) is reached with the arrow keys.
    static func keyViews(in root: NSView) -> [NSView] {
        func collect(_ v: NSView) -> [NSView] {
            guard !v.isHiddenOrHasHiddenAncestor, v.window != nil, !v.visibleRect.isEmpty else { return [] }
            return v.canBecomeKeyView ? [v] : v.subviews.flatMap(collect)
        }
        return collect(root).sorted { a, b in
            let ra = a.convert(a.bounds, to: nil), rb = b.convert(b.bounds, to: nil)
            // Window coordinates grow upward: the higher one comes first; on one line, the one on the left.
            if abs(ra.maxY - rb.maxY) > 4 { return ra.maxY > rb.maxY }
            return ra.minX < rb.minX
        }
    }

    /// The next (or previous) stop after the focused view, or nil when the focus is somewhere the loop doesn't know
    /// (AppKit's own order then applies).
    func keyLoopStop(after responder: NSResponder?, backwards: Bool) -> NSView? {
        let loop = keyLoop
        guard !loop.isEmpty, var view = Self.focusedView(responder) else { return nil }
        // Focus inside a stop (the location's text field, a control in a bar) counts as that stop.
        while !loop.contains(where: { $0 === view }) {
            guard let up = view.superview else { return nil }
            view = up
        }
        guard let i = loop.firstIndex(where: { $0 === view }) else { return nil }
        return loop[(i + (backwards ? loop.count - 1 : 1)) % loop.count]
    }

    /// The view that has the focus: a text field's own view while its field editor is typing in it.
    static func focusedView(_ responder: NSResponder?) -> NSView? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
        return responder as? NSView
    }

    /// Esc in the terminal at its prompt: back to the list. With a program running (vim, less, top), Esc is theirs.
    func leaveTerminalOnEscape(_ event: NSEvent) -> Bool {
        guard showTerminal, event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
            window?.firstResponder === terminal.terminalView, !terminal.hasRunningProgram
        else { return false }
        window?.makeFirstResponder(view.list)
        return true
    }

    // MARK: Focus actions (View › Show Panels)

    @objc func focusFolders(_ sender: Any?) { focusPanel(\.showFolders, folders) }
    @objc func focusShelf(_ sender: Any?) { focusPanel(\.showShelf, shelf) }
    @objc func focusInformation(_ sender: Any?) { focusPanel(\.showInformation, information) }

    /// Shows the panel if it's hidden and moves the focus into it (as Focus Places does); pressed again while it has
    /// the focus, back to the list.
    private func focusPanel(_ shown: ReferenceWritableKeyPath<MainWindowController, Bool>, _ root: NSView) {
        if let f = Self.focusedView(window?.firstResponder), f === root || f.isDescendant(of: root) {
            window?.makeFirstResponder(view.list)
            return
        }
        if !self[keyPath: shown] {
            self[keyPath: shown] = true
            rebuildPanels()
            window?.layoutIfNeeded()
        }
        if let target = Self.keyViews(in: root).first { window?.makeFirstResponder(target) }
    }
}
