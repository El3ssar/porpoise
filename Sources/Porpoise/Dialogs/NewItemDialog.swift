import AppKit
import PorpoiseCore
import PorpoiseFileSystem
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
    static let htmlTemplate = Data(
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title></title>\n</head>\n<body>\n</body>\n</html>\n".utf8)

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
    /// A cloud folder or a server's: the names in it (for the suggested name and the check), its name, and what
    /// creates the item.
    private var named: (names: Set<String>, title: String, create: (String) -> Void)?

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

    /// The same dialog for a folder elsewhere (a cloud service, a server); `create` gets the name and makes the item.
    /// Where the service allows two items of the same name (Drive) an existing name is only noted; elsewhere it is
    /// refused, ignoring case as many services and servers do.
    static func runNamed(
        _ kind: NewItemKind = .folder, in folder: URL, title: String, names: Set<String>, window: NSWindow?, create: @escaping (String) -> Void
    ) {
        let d = NewItemDialog(kind: kind, folder: folder)
        d.named = (names, title, create)
        active = d
        d.present(window: window) { _ in }
    }

    private func present(window: NSWindow?, done: @escaping (URL) -> Void) {
        alert.messageText = kind == .folder ? "Create New Folder" : "Create \(kind.menuTitle.replacingOccurrences(of: "…", with: ""))"
        alert.informativeText = kind == .folder ? "Create new folder in:\n\(named?.title ?? folder.path)" : "File name:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.icon = Icons.shared.image(kind.icon, size: 64)
        let hasTarget = kind == .link || kind == .urlLink
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: hasTarget ? 86 : 50))
        let existing = named?.names ?? Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
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
            if let named { named.create(nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)); return }
            do {
                let url: URL
                switch kind {
                case .folder: url = try FileActions.makeFolder(named: nameField.stringValue, in: folder)
                case .textFile, .emptyFile: url = try FileActions.makeFile(named: nameField.stringValue, in: folder)
                case .htmlFile:
                    url = try FileActions.makeFile(named: nameField.stringValue, in: folder, contents: NewItemKind.htmlTemplate)
                case .link:
                    url = folder.appendingPathComponent(nameField.stringValue)
                    try FileManager.default.createSymbolicLink(
                        atPath: url.path, withDestinationPath: (targetField.stringValue as NSString).expandingTildeInPath)
                case .urlLink:
                    let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": targetField.stringValue], format: .xml, options: 0)
                    url = try FileActions.makeFile(named: finalName, in: folder, contents: plist)
                }
                done(url)
            } catch  where FileErrorKind.classify(error) == .permission {
                // Protected folder: create it as administrator, as the normal path would ("a/b" makes both folders)
                // and never over something that appeared meanwhile.
                let dst = folder.appendingPathComponent(finalName)
                var tempFile: URL?
                var data = Data()
                if kind == .htmlFile { data = NewItemKind.htmlTemplate }
                if kind == .urlLink {
                    data =
                        (try? PropertyListSerialization.data(fromPropertyList: ["URL": targetField.stringValue], format: .xml, options: 0)) ?? Data()
                }
                if ![.folder, .link].contains(kind) {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do { try data.write(to: tmp) } catch {
                        DispatchQueue.main.async { NSAlert(error: error).runSheet(for: window) { _ in } }
                        return
                    }
                    tempFile = tmp
                }
                let commands = Self.administratorCommands(
                    kind, at: dst, in: folder, linkTarget: (targetField.stringValue as NSString).expandingTildeInPath, contents: tempFile)
                let ok = FileOperationsController.shared.authorize(verb: "create an item in", items: [folder], commands: commands, window: window)
                if let t = tempFile { try? FileManager.default.removeItem(at: t) }  // also when the prompt was cancelled
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

    /// The name the item gets: a link to a location ends in ".webloc".
    private var finalName: String { Self.finalName(nameField.stringValue, kind: kind) }

    static func finalName(_ n: String, kind: NewItemKind) -> String { kind == .urlLink && !n.hasSuffix(".webloc") ? n + ".webloc" : n }

    /// What creates the item as administrator. Folders: each missing one on the way ("a/b"). Files: copied next to
    /// where they go under a temporary name, then moved in without replacing (`mv -n`): an item that appeared there
    /// since stays, and the leftover copy goes.
    static func administratorCommands(_ kind: NewItemKind, at dst: URL, in folder: URL, linkTarget: String, contents: URL?) -> [[String]] {
        switch kind {
        case .folder:
            var missing: [URL] = []
            var u = dst
            while u.path.count > folder.path.count, !FileManager.default.fileExists(atPath: u.path) {
                missing.insert(u, at: 0)
                u = u.deletingLastPathComponent()
            }
            return missing.map { ["/bin/mkdir", "--", $0.path] }
        case .link:
            return [["/bin/ln", "-s", "--", linkTarget, dst.path]]
        default:
            guard let contents else { return [] }
            let staged = dst.deletingLastPathComponent().appendingPathComponent(".porpoise-new-\(UUID().uuidString)").path
            return [["/bin/cp", "--", contents.path, staged], ["/bin/mv", "-n", "--", staged, dst.path], ["/bin/rm", "-rf", "--", staged]]
        }
    }

    /// What to say about a new item's name in a folder elsewhere: nothing, a note (the service keeps both), or an error.
    static func nameProblem(_ name: String, names: Set<String>, in folder: URL) -> (message: String, isError: Bool)? {
        let duplicates = CloudProviderDescriptor.descriptor(for: folder)?.allowsDuplicateNames ?? false
        if duplicates {
            return names.contains(name) ? ("“\(name)” is already in this folder. Both will be kept.", false) : nil
        }
        let taken = names.contains { $0.compare(name, options: [.caseInsensitive]) == .orderedSame }
        return taken ? ("An item named “\(name)” is already in this folder.", true) : nil
    }

    private func validate() {
        if let named {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let problem = Self.nameProblem(name, names: named.names, in: folder)
            message.stringValue = problem?.message ?? ""
            message.textColor = problem?.isError == true ? Theme.negativeText : Theme.neutralText
            alert.buttons.first?.isEnabled = !name.isEmpty && problem?.isError != true
            return
        }
        // The name it will have: "Link" is taken when "Link.webloc" is there.
        let res = FileActions.validateName(finalName, in: folder, allowSlash: kind == .folder)
        message.stringValue = res?.message ?? ""
        message.textColor = (res?.isError ?? false) ? Theme.negativeText : Theme.neutralText
        // Links need a target: an empty one would make a dangling symlink or an empty .webloc.
        let missingTarget = (kind == .link || kind == .urlLink) && targetField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        alert.buttons.first?.isEnabled = !(res?.isError ?? false) && !missingTarget
    }
}
