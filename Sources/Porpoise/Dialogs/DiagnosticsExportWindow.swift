import AppKit
import PorpoiseServices

/// Help › Export Diagnostics…: the diagnostic events as they will be saved, then a file the user chooses. What is shown
/// is the reviewed snapshot itself, and Save writes exactly those bytes; nothing is sent anywhere.
final class DiagnosticsExportWindowController: SecondaryWindowController {
    /// The snapshot shown and saved: events recorded after the window opened aren't in it.
    let export: DiagnosticExport
    let textView = NSTextView()
    /// After a save, with where the file went (Report a Bug attaches it).
    var onSaved: ((URL) -> Void)?

    init(export: DiagnosticExport) {
        self.export = export
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Export Diagnostics"
        window.contentMinSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Opens on the events recorded so far, or says why it can't. `onSaved`: after a save, with the file's location.
    static func show(onSaved: ((URL) -> Void)? = nil) {
        do {
            let controller = DiagnosticsExportWindowController(export: try Diagnostics.shared.preview())
            controller.onSaved = onSaved
            controller.present()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Porpoise couldn't prepare its diagnostics."
            alert.informativeText = "Try again in a moment."
            alert.runModal()
        }
    }

    private func build() {
        let stack = contentStack()
        let note = NSTextField(
            wrappingLabelWithString:
                "Porpoise keeps a short record of recent errors in memory: what kind of error, when, and your app and macOS versions. It never includes file or folder names, paths, accounts, servers or messages. Below is exactly what will be saved. Nothing is sent anywhere; you choose who to share the file with."
        )
        note.font = Theme.smallFont
        note.textColor = Theme.windowTextInactive

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: Theme.fontSize - 1, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = export.text
        scroll.documentView = textView
        textView.setAccessibilityLabel("Diagnostics to be saved")

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save…", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal

        for v in [note, scroll, buttons] as [NSView] {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    @objc private func cancel(_ sender: Any?) { window?.close() }

    @objc private func save(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Porpoise Diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.write(to: url)
                window.close()
                self.onSaved?(url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// The snapshot's bytes to `url`. The save panel has already asked before replacing a file there.
    func write(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try export.write(to: url)
    }
}
