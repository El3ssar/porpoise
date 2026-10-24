import AppKit
import PorpoiseCore
import PorpoiseServices

/// Every local-file entry point uses the executable policy before choosing an associated application.
@MainActor struct LocalFileOpening {
    var run: (URL) -> Void = { ExternalTerminal.run($0) }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var applications: (URL) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) }
    var openWithApplication: (URL, URL) -> Void = {
        NSWorkspace.shared.open([$0], withApplicationAt: $1, configuration: NSWorkspace.OpenConfiguration())
    }
    var ask: (FileItem, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { item, window, completed in
        let alert = NSAlert()
        alert.messageText = "“\(item.name)” is an executable file. Do you want to run it, or open it in an application?"
        alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        alert.runSheet(for: window, completed)
    }

    func open(_ item: FileItem, secondApplication: Bool = false, window: NSWindow?, completed: @escaping () -> Void) {
        let executable =
            item.url.isFileURL && !item.isDirectory && item.posixPermissions & 0o111 != 0
            && (item.utType.map { $0.conforms(to: .shellScript) || $0.conforms(to: .unixExecutable) || $0.conforms(to: .script) } ?? false)
        if executable {
            switch Settings.shared.executableAction {
            case .run: run(item.url)
            case .open: open(item.url)
            case .ask:
                ask(item, window) { response in
                    if response == .alertFirstButtonReturn { run(item.url) }
                    if response == .alertSecondButtonReturn { open(item.url) }
                    completed()
                }
                return
            }
        } else if secondApplication, let app = applications(item.url).dropFirst().first {
            openWithApplication(item.url, app)
        } else {
            open(item.url)
        }
        completed()
    }
}
