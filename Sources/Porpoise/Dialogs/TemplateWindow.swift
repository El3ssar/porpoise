import AppKit
import PorpoiseCore
import PorpoiseServices
import UniformTypeIdentifiers

/// Editable source and resolved preview share one frozen date/context until the file is created.
final class TemplateWindow: SecondaryWindowController, NSTextFieldDelegate, NSTextViewDelegate {
    private let folder: URL
    private let done: (URL) -> Void
    private let store = TemplateStore.shared
    private var templates: [FileTemplate] = []
    private let picker = NSPopUpButton()
    private let filename = NSTextField()
    private let personalName = NSTextField()
    private let source = NSTextView()
    private let preview = NSTextView()
    private let resolved = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let create = ClosureButton(title: "Create") { _ in }
    private let saveTemplate = ClosureButton(title: "Save as Personal Template") { _ in }
    private var storageWarning: String?
    private var binary: Data?
    private let date = Date()

    init(folder: URL, done: @escaping (URL) -> Void) {
        self.folder = folder; self.done = done
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Create From Template"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = contentStack(insets: NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20))
        let target = NSTextField(wrappingLabelWithString: "Create in: \(folder.path)"); target.maximumNumberOfLines = 2;
        stack.addArrangedSubview(target)
        picker.target = self; picker.action = #selector(changedTemplate); picker.setAccessibilityLabel("Template")
        stack.addArrangedSubview(picker)
        filename.placeholderString = "File name or pattern"; filename.delegate = self; filename.setAccessibilityLabel("File name pattern")
        personalName.placeholderString = "Personal template name"; personalName.delegate = self;
        personalName.setAccessibilityLabel("Personal template name")
        stack.addArrangedSubview(NSTextField(labelWithString: "File name pattern")); stack.addArrangedSubview(filename)
        resolved.font = .monospacedSystemFont(ofSize: 12, weight: .regular); resolved.isSelectable = true
        stack.addArrangedSubview(resolved)
        let help = NSTextField(
            wrappingLabelWithString:
                "Variables: {date} · {time} · {user} · {name} · {counter} or {counter:03}. The counter chooses the next unused name. In the contents, {name} is the final name without its extension."
        )
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor; stack.addArrangedSubview(help)
        let editors = NSStackView(); editors.orientation = .horizontal; editors.distribution = .fillEqually; editors.spacing = 12
        for (title, text) in [("Template Contents", source), ("Preview", preview)] {
            let column = NSStackView(); column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
            column.addArrangedSubview(NSTextField(labelWithString: title))
            let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textContainerInset = NSSize(width: 8, height: 8); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.setAccessibilityLabel(title); column.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            editors.addArrangedSubview(column)
        }
        preview.isEditable = false; source.delegate = self
        stack.addArrangedSubview(editors); editors.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        editors.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(NSTextField(labelWithString: "Personal template name"))
        stack.addArrangedSubview(personalName)
        saveTemplate.handler = { [weak self] _ in self?.savePersonal() }
        let tools = NSStackView(views: [
            saveTemplate,
            ClosureButton(title: "Import…") { [weak self] _ in self?.importTemplate() },
            ClosureButton(title: "Export…") { [weak self] _ in self?.exportTemplate() },
            ClosureButton(title: "Templates Folder") { [weak self] _ in self?.openFolder() },
        ]); tools.spacing = 8; stack.addArrangedSubview(tools)
        status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 3; stack.addArrangedSubview(status)
        let buttons = NSStackView(views: [ClosureButton(title: "Cancel") { [weak self] _ in self?.close() }, create]); buttons.spacing = 8
        stack.addArrangedSubview(buttons); create.keyEquivalent = "\r"; create.handler = { [weak self] _ in self?.createFile() }
        for view in [filename, personalName, resolved, help, status] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.minSize = NSSize(width: 820, height: 620); window.center()
        reload(); choose()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func reload(select id: UUID? = nil) {
        templates = FileTemplate.builtins
        do {
            templates += try store.personal(); storageWarning = nil
        } catch { storageWarning = "Personal templates unavailable: " + error.localizedDescription }
        picker.removeAllItems()
        picker.addItems(withTitles: templates.enumerated().map { $0.element.title + ($0.offset >= FileTemplate.builtins.count ? " (Personal)" : "") })
        if let id, let index = templates.firstIndex(where: { $0.id == id }) { picker.selectItem(at: index) }
    }
    @objc private func changedTemplate() { choose() }
    private func choose() {
        guard templates.indices.contains(picker.indexOfSelectedItem) else { return }
        let template = templates[picker.indexOfSelectedItem]
        saveTemplate.title = picker.indexOfSelectedItem >= FileTemplate.builtins.count ? "Save Personal Template" : "Save as Personal Template"
        filename.stringValue = template.filename; personalName.stringValue = template.title
        if let text = template.textContents {
            binary = nil; source.string = text; source.isEditable = true
        } else {
            binary = template.contents; source.string = "Binary template (\(template.contents.count.formatted()) bytes)"; source.isEditable = false
        }
        updatePreview()
    }
    private var current: FileTemplate {
        let index = picker.indexOfSelectedItem
        let id = templates.indices.contains(index) && index >= FileTemplate.builtins.count ? templates[index].id : UUID()
        return FileTemplate(id: id, title: personalName.stringValue, filename: filename.stringValue, contents: binary ?? Data(source.string.utf8))
    }
    private var context: TemplateContext {
        TemplateContext(date: date, name: personalName.stringValue.isEmpty ? "New File" : personalName.stringValue)
    }
    func controlTextDidChange(_ notification: Notification) { updatePreview() }
    func textDidChange(_ notification: Notification) { updatePreview() }
    private func updatePreview() {
        do {
            let result = try store.preview(current, pattern: filename.stringValue, folder: folder, context: context)
            resolved.stringValue = "Creates: " + result.name
            preview.string =
                binary == nil
                ? String(decoding: result.contents.prefix(64 * 1024), as: UTF8.self) : "Binary contents (\(result.contents.count.formatted()) bytes)"
            status.stringValue =
                result.contents.count > 64 * 1024
                ? "Preview shows the first 64 KiB; the complete contents will be created." : "Ready to create. Existing files are kept."
            if let storageWarning { status.stringValue += " " + storageWarning }
            status.textColor = Theme.windowTextInactive; create.isEnabled = true
        } catch {
            resolved.stringValue = ""; preview.string = ""; status.stringValue = error.localizedDescription; status.textColor = Theme.negativeText;
            create.isEnabled = false
        }
    }
    private func createFile() {
        do { let url = try store.create(current, pattern: filename.stringValue, folder: folder, context: context); close(); done(url) } catch {
            status.stringValue = error.localizedDescription; status.textColor = Theme.negativeText
        }
    }
    private func savePersonal() {
        do {
            let template = current; try store.save(template); reload(select: template.id); choose();
            status.stringValue = "Saved in \(store.directory.path)"
        } catch { status.stringValue = error.localizedDescription }
    }
    private func importTemplate() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { let template = try self.store.importTemplate(url); self.reload(select: template.id); self.choose() } catch {
                self.status.stringValue = error.localizedDescription
            }
        }
    }
    private func exportTemplate() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Template.json"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.store.export(self.current, to: url); self.status.stringValue = "Exported template." } catch {
                self.status.stringValue = error.localizedDescription
            }
        }
    }
    private func openFolder() {
        do { try store.prepare(); NSWorkspace.shared.open(store.directory) } catch { status.stringValue = error.localizedDescription }
    }
}
