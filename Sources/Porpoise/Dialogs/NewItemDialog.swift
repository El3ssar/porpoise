import AppKit
import PorpoiseCore
import PorpoiseServices

enum NewItemKind: Int, CaseIterable {
    case folder, textFile, htmlFile, emptyFile, link, urlLink

    var menuTitle: String {
        switch self {
        case .folder: return "Folder…"
        case .textFile: return "Text File…"
        case .htmlFile: return "HTML File…"
        case .emptyFile: return "Empty File…"
        case .link: return "Link to File or Folder…"
        case .urlLink: return "Link to Location (URL)…"
        }
    }

    var icon: String {
        switch self {
        case .folder: return "folder-new"
        case .textFile: return "text-plain"
        case .htmlFile: return "text-html"
        case .emptyFile: return "document-new"
        case .link: return "insert-link"
        case .urlLink: return "link"
        }
    }

    /// Contents of a new HTML file.
    static let htmlTemplate = Data("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title></title>\n</head>\n<body>\n</body>\n</html>\n".utf8)

    var defaultName: String {
        switch self {
        case .folder: return "New Folder"
        case .textFile: return "Text File.txt"
        case .htmlFile: return "HTML File.html"
        case .emptyFile: return "Empty File"
        case .link: return "Link"
        case .urlLink: return "Link.webloc"
        }
    }
}

/// KIO's "Create New" dialogs: name field with live validation (exists / leading dot / slashes).
final class NewItemDialog: NSObject, NSTextFieldDelegate {
    private let kind: NewItemKind
    private let folder: URL
    private let alert = NSAlert()
    private let nameField = NSTextField()
    private let targetField = NSTextField()
    private let message = NSTextField(labelWithString: "")
    private static var active: NewItemDialog?

    private init(kind: NewItemKind, folder: URL) {
        self.kind = kind
        self.folder = folder
        super.init()
    }

    static func run(kind: NewItemKind, in folder: URL, window: NSWindow?, done: @escaping (URL) -> Void) {
        let d = NewItemDialog(kind: kind, folder: folder)
        active = d
        d.present(window: window, done: done)
    }

    private func present(window: NSWindow?, done: @escaping (URL) -> Void) {
        alert.messageText = kind == .folder ? "Create New Folder" : "Create \(kind.menuTitle.replacingOccurrences(of: "…", with: ""))"
        alert.informativeText = kind == .folder ? "Create new folder in:\n\(folder.path)" : "File name:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.icon = Icons.shared.image(kind.icon, size: 64)
        let hasTarget = kind == .link || kind == .urlLink
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: hasTarget ? 86 : 50))
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var name = kind.defaultName
        if existing.contains(name) { name = FileFormat.suggestedName(for: name, existing: existing) }
        nameField.stringValue = name
        nameField.frame = CGRect(x: 0, y: v.frame.height - 24, width: 340, height: 24)
        nameField.delegate = self
        message.frame = CGRect(x: 0, y: v.frame.height - 46, width: 340, height: 18)
        message.font = Theme.smallFont
        v.addSubview(nameField)
        v.addSubview(message)
        if hasTarget {
            targetField.placeholderString = kind == .urlLink ? "https://…" : "Path to the target"
            targetField.frame = CGRect(x: 0, y: 4, width: 340, height: 24)
            targetField.delegate = self
            v.addSubview(targetField)
        }
        alert.accessoryView = v
        alert.window.initialFirstResponder = nameField
        validate()
        let handler: (NSApplication.ModalResponse) -> Void = { [self] r in
            defer { NewItemDialog.active = nil }
            guard r == .alertFirstButtonReturn else { return }
            do {
                let url: URL
                switch kind {
                case .folder: url = try FileActions.makeFolder(named: nameField.stringValue, in: folder)
                case .textFile, .emptyFile: url = try FileActions.makeFile(named: nameField.stringValue, in: folder)
                case .htmlFile:
                    url = try FileActions.makeFile(named: nameField.stringValue, in: folder, contents: NewItemKind.htmlTemplate)
                case .link:
                    url = folder.appendingPathComponent(nameField.stringValue)
                    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: (targetField.stringValue as NSString).expandingTildeInPath)
                case .urlLink:
                    let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": targetField.stringValue], format: .xml, options: 0)
                    var n = nameField.stringValue
                    if !n.hasSuffix(".webloc") { n += ".webloc" }
                    url = try FileActions.makeFile(named: n, in: folder, contents: plist)
                }
                done(url)
            } catch where FileJob.isPermissionError(error) {
                // Protected folder: create it as administrator.
                var n = nameField.stringValue
                if kind == .urlLink && !n.hasSuffix(".webloc") { n += ".webloc" }
                let dst = folder.appendingPathComponent(n)
                var cmd: [String]
                var tempFile: URL?
                switch kind {
                case .folder: cmd = ["/bin/mkdir", "--", dst.path]
                case .link: cmd = ["/bin/ln", "-s", "--", (targetField.stringValue as NSString).expandingTildeInPath, dst.path]
                default:
                    // Write the contents to a temporary file first, then copy it into place.
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    var data = Data()
                    if kind == .htmlFile { data = NewItemKind.htmlTemplate }
                    if kind == .urlLink { data = (try? PropertyListSerialization.data(fromPropertyList: ["URL": targetField.stringValue], format: .xml, options: 0)) ?? Data() }
                    try? data.write(to: tmp)
                    cmd = ["/bin/cp", "--", tmp.path, dst.path]
                    tempFile = tmp
                }
                let ok = FileOperationsController.shared.authorize(verb: "create an item in", items: [folder], commands: [cmd], window: window)
                if let t = tempFile { try? FileManager.default.removeItem(at: t) }   // also when the prompt was cancelled
                if ok { done(dst) }
            } catch {
                // After the sheet has gone, or the error sheet could not attach.
                DispatchQueue.main.async { NSAlert(error: error).runSheet(for: window) { _ in } }
            }
        }
        alert.runSheet(for: window, handler)
        // Select the name without extension.
        DispatchQueue.main.async { [self] in
            if let ed = nameField.currentEditor() {
                let ns = nameField.stringValue as NSString
                let ext = ns.pathExtension
                ed.selectedRange = NSRange(location: 0, length: ext.isEmpty || kind == .folder ? ns.length : ns.length - ext.count - 1)
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) { validate() }

    private func validate() {
        let res = FileActions.validateName(nameField.stringValue, in: folder, allowSlash: kind == .folder)
        message.stringValue = res?.message ?? ""
        message.textColor = (res?.isError ?? false) ? Theme.negativeText : Theme.neutralText
        // Links need a target: an empty one would make a dangling symlink or an empty .webloc.
        let missingTarget = (kind == .link || kind == .urlLink) && targetField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        alert.buttons.first?.isEnabled = !(res?.isError ?? false) && !missingTarget
    }
}
