import AppKit

extension NSAlert {
    /// The one way alerts are shown: as a sheet on `window` while it's on screen, else on their own (app-modal). A
    /// question can come long after it was asked for (a sign-in back from the browser, a folder counted, a disk
    /// unmounted, a job's errors), when its window may be closed or hidden: a sheet there would never be seen.
    func runSheet(for window: NSWindow?, _ done: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        if let window, window.isVisible { beginSheetModal(for: window, completionHandler: done) } else { done(runModal()) }
    }
}

/// The alerts the app asks again and again, built one way and shown with `runSheet`.
enum Prompt {
    /// A message with an OK button.
    static func message(_ text: String, detail: String? = nil, warning: Bool = false, on window: NSWindow?) {
        let a = NSAlert()
        if warning { a.alertStyle = .warning }
        a.messageText = text
        if let detail { a.informativeText = detail }
        a.runSheet(for: window)
    }

    /// A question with `confirm` and Cancel (`destructive`: the confirm button is marked so). `done` gets whether it
    /// was confirmed.
    static func confirm(
        _ text: String, detail: String, confirm: String, destructive: Bool = false, on window: NSWindow?, _ done: @escaping (Bool) -> Void
    ) {
        let a = NSAlert()
        a.messageText = text
        a.informativeText = detail
        a.addButton(withTitle: confirm)
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = destructive
        a.runSheet(for: window) { done($0 == .alertFirstButtonReturn) }
    }

    /// One line of text to type (a name), with `confirm` and Cancel. `done` gets the text when confirmed.
    static func text(
        _ title: String, detail: String? = nil, value: String, confirm: String, width: CGFloat = 260, on window: NSWindow?,
        _ done: @escaping (String) -> Void
    ) {
        let a = NSAlert()
        a.messageText = title
        if let detail { a.informativeText = detail }
        let field = NSTextField(string: value)
        field.frame = CGRect(x: 0, y: 0, width: width, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: confirm)
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        a.runSheet(for: window) { if $0 == .alertFirstButtonReturn { done(field.stringValue) } }
    }
}
