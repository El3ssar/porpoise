import AppKit
import PorpoiseServices

/// Launch argument vectors avoid shell interpolation and preserve paths containing spaces or shell characters.
enum FileDiffExternalTools {
    struct Tool { let name: String; let url: URL }
    static var installed: [Tool] {
        let ids = [
            ("FileMerge", "com.apple.FileMerge"), ("Kaleidoscope", "com.blackpixel.kaleidoscope"),
            ("Beyond Compare", "com.scootersoftware.BeyondCompare"), ("BBEdit", "com.barebones.bbedit"), ("VS Code", "com.microsoft.VSCode"),
        ]
        var values = ids.compactMap { name, id in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { Tool(name: name, url: $0) } }
        // Versioned bundle IDs change; normal installations remain discoverable by their app name.
        let appNames = [
            ("Kaleidoscope", "Kaleidoscope"), ("Beyond Compare", "Beyond Compare"), ("BBEdit", "BBEdit"), ("VS Code", "Visual Studio Code"),
        ]
        let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        for (name, filename) in appNames where !values.contains(where: { $0.name == name }) {
            if let url = folders.map({ $0.appendingPathComponent(filename + ".app") }).first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) {
                values.append(Tool(name: name, url: url))
            }
        }
        if !values.contains(where: { $0.name == "FileMerge" }),
            FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Applications/FileMerge.app")
        {
            values.append(Tool(name: "FileMerge", url: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/FileMerge.app")))
        }
        if let path = Settings.store.string(forKey: "fileDiff.defaultApp"), FileManager.default.fileExists(atPath: path),
            !values.contains(where: { $0.url.path == path })
        {
            let url = URL(fileURLWithPath: path); values.append(Tool(name: url.deletingPathExtension().lastPathComponent, url: url))
        }
        let last = Settings.store.string(forKey: "fileDiff.lastApp") ?? Settings.store.string(forKey: "fileDiff.defaultApp")
        return values.sorted { ($0.url.path == last ? 0 : 1, $0.name) < ($1.url.path == last ? 0 : 1, $1.name) }
    }
    static func open(_ app: URL, left: URL, right: URL, error: @escaping (Error) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        let name = app.lastPathComponent.lowercased()
        if name.contains("bbedit") {
            // Bare Bones documents bbdiff as the Find Differences entry point:
            // https://www.barebones.com/products/bbedit/benefitsintegrate.html
            let helpers = [
                app.appendingPathComponent("Contents/Helpers/bbdiff"), app.appendingPathComponent("Contents/Resources/bbdiff"),
                URL(fileURLWithPath: "/usr/local/bin/bbdiff"),
            ]
            guard let helper = helpers.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                error(
                    NSError(
                        domain: "PorpoiseFileDiff", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "BBEdit’s comparison helper isn’t available. Install its command-line tools, then try again."
                        ]));
                return
            }
            let process = Process(); process.executableURL = helper; process.arguments = [left.path, right.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus != 0 {
                    DispatchQueue.main.async {
                        error(
                            NSError(
                                domain: "PorpoiseFileDiff", code: Int(process.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: "BBEdit couldn’t open this comparison."]))
                    }
                }
            }
            do { try process.run() } catch let failure { error(failure) }
        } else if name.contains("visual studio code") {
            // NSWorkspace only delivers command-line arguments to a new instance.
            config.createsNewApplicationInstance = true
            config.arguments = ["--diff", left.path, right.path]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, e in if let e { DispatchQueue.main.async { error(e) } } }
        } else if name.contains("filemerge") || name.contains("beyond compare") {
            config.createsNewApplicationInstance = true
            config.arguments = name.contains("filemerge") ? ["-left", left.path, "-right", right.path] : [left.path, right.path]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, e in if let e { DispatchQueue.main.async { error(e) } } }
        } else {
            NSWorkspace.shared.open([left, right], withApplicationAt: app, configuration: config) { _, e in
                if let e { DispatchQueue.main.async { error(e) } }
            }
        }
        Settings.store.set(app.path, forKey: "fileDiff.lastApp")
    }
    static func chooseDefault(window: NSWindow?, done: @escaping () -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.message = "Choose the app Porpoise uses to compare files."
        panel.beginSheetModal(for: window!) { response in
            if response == .OK, let url = panel.url {
                Settings.store.set(url.path, forKey: "fileDiff.defaultApp");
                NotificationCenter.default.post(name: Settings.changed, object: "fileDiff.defaultApp"); done()
            }
        }
    }
}
