import AppKit
import PorpoiseCore
import PorpoiseServices

/// Launches the selected terminal using explicit argv, preserving spaces and shell metacharacters in paths.
enum ExternalTerminal {
    static var installed: [ExternalTerminalChoice] {
        ExternalTerminalChoice.installed { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
    static func run(_ file: URL) { launch(at: file.deletingLastPathComponent(), script: file) }
    static func open(at dir: URL) { launch(at: dir, script: nil) }

    private static func launch(at dir: URL, script: URL?) {
        let preferences = Settings.shared.appearancePreferences
        if preferences.externalTerminal == .custom {
            do {
                var command = try TerminalCommandTemplate.expand(preferences.externalCommand, directory: dir.path)
                if let script { command += " " + TerminalCommandTemplate.quote(script.path) }
                try process("/bin/sh", ["-c", command])
            } catch { NSAlert(error: error).runModal() }
            return
        }
        let choices: [ExternalTerminalChoice] =
            preferences.externalTerminal == .automatic
            ? [.kitty, .ghostty, .iTerm, .wezTerm, .terminal] : [preferences.externalTerminal]
        for choice in choices {
            guard let id = choice.bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let path = dir.path
            var executable: String?, arguments: [String] = []
            switch choice {
            case .kitty:
                executable = "kitty"; arguments = ["--single-instance", "--directory", path] + (script.map { ["--hold", $0.path] } ?? [])
            case .wezTerm:
                executable = "wezterm"; arguments = ["start", "--cwd", path] + (script.map { ["--", $0.path] } ?? [])
            case .ghostty:
                executable = "ghostty"; arguments = ["--working-directory=" + path] + (script.map { ["-e", $0.path] } ?? [])
            case .alacritty:
                executable = "alacritty"; arguments = ["--working-directory", path] + (script.map { ["-e", $0.path] } ?? [])
            default: break
            }
            if let executable {
                do { try process(app.appendingPathComponent("Contents/MacOS/" + executable).path, arguments) } catch {
                    NSAlert(error: error).runModal()
                }
            } else {
                NSWorkspace.shared.open([script ?? dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        let alert = NSAlert(); alert.messageText = "The selected terminal is not installed"
        alert.informativeText = "Choose an installed terminal in Settings › Appearance."; alert.runModal()
    }
    private static func process(_ executable: String, _ arguments: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments; try p.run()
    }
}
