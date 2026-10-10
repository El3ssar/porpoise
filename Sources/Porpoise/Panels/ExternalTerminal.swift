import AppKit
import PorpoiseCore
import PorpoiseServices

/// Opens an external terminal app at a folder (Dolphin's "Open Terminal Here"). Prefers kitty if installed.
enum ExternalTerminal {
    private static let kittyID = "net.kovidgoyal.kitty"

    /// Runs an executable in a terminal window (Dolphin's "Run script").
    static func run(_ file: URL) {
        let ws = NSWorkspace.shared
        if let kitty = ws.urlForApplication(withBundleIdentifier: kittyID),
           launchKitty(kitty, ["--single-instance", "--hold", "--directory", file.deletingLastPathComponent().path, file.path]) { return }
        if let term = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            ws.open([file], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func open(at dir: URL) {
        let ws = NSWorkspace.shared
        let candidates = [kittyID, "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.github.wez.wezterm", "com.apple.Terminal"]
        let preferred = Settings.store.string(forKey: "terminalApp")
        for id in [preferred].compactMap({ $0 }) + candidates {
            guard let app = ws.urlForApplication(withBundleIdentifier: id) else { continue }
            if id == kittyID, launchKitty(app, ["--single-instance", "--directory", dir.path]) { return }
            ws.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
    }

    /// kitty opens folders as a working directory only through its command line.
    private static func launchKitty(_ app: URL, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/kitty")
        p.arguments = args
        return (try? p.run()) != nil
    }
}
