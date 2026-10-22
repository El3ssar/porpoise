import AppKit
import PorpoiseCore
import PorpoiseServices

/// The Terminal panel and the external terminal: shell, font, colors, cursor, and what "Open Terminal Here" runs.
enum TerminalSettingsPage {
    static func build(_ f: FormBuilder) {
        let s = Settings.shared
        f.section("Terminal panel")
        f.check("Follow folder changes (both directions)", s.terminalFollowsDirectory) { s.terminalFollowsDirectory = $0 }
        f.section("Shell")
        f.popup("Shell:", ShellChoice.allCases.map(\.title), ShellChoice.allCases.firstIndex(of: s.appearancePreferences.shell) ?? 0) { i in
            s.updateAppearance { $0.shell = ShellChoice.allCases[i] }
        }
        f.text("Custom shell path:", s.appearancePreferences.customShell) { v in
            s.updateAppearance { $0.customShell = (v as NSString).expandingTildeInPath }
        }
        f.text("Arguments (JSON):", AppearancePage.argumentsJSON()) { [weak f] value in
            guard let args = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) else { NSSound.beep(); f?.refresh(); return }
            s.updateAppearance { $0.shellArguments = args }
        }
        f.note("Shell changes apply when a new terminal session starts. Arguments are a JSON array, for example [\"-l\"].")
        f.fontPicker("Terminal font:", name: s.appearancePreferences.terminalFontName, size: s.appearancePreferences.terminalFontSize) { name, size in
            s.updateAppearance {
                $0.terminalFontName = name; $0.terminalFontSize = size
            }
        }
        let schemes = ["Follow theme"] + TerminalPalette.builtIns.map(\.name) + ["Custom"]
        f.popup("Terminal colors:", schemes, schemes.firstIndex(of: s.appearancePreferences.terminalScheme) ?? 0) { i in
            s.updateAppearance { $0.terminalScheme = schemes[i] }
        }
        f.button("Import Terminal Colors…") {
            AppearancePage.readFile(extensions: ["itermcolors", "colorscheme"]) { url, data in
                let palette =
                    try url.pathExtension.lowercased() == "itermcolors"
                    ? TerminalPalette.iTerm(data, name: url.deletingPathExtension().lastPathComponent)
                    : TerminalPalette.konsole(String(decoding: data, as: UTF8.self), name: url.deletingPathExtension().lastPathComponent)
                s.updateAppearance {
                    $0.customTerminalPalette = palette; $0.terminalScheme = "Custom"
                }
            }
        }
        f.colorGrid(
            (0..<16).map { "ANSI \($0)" },
            values: { index in
                let c = s.appearancePreferences.theme(dark: Theme.isDark).terminalPalette[index]
                return NSColor(rgb: c.red, c.green, c.blue)
            },
            set: { index, color in
                guard let c = color.usingColorSpace(.sRGB) else { return }
                s.updateAppearance { p in
                    var theme = Theme.palette(dark: Theme.isDark)
                    theme.terminalPalette[index] = ThemeColor(
                        Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                    theme.name = "Custom"; p.customTheme = theme; p.themeName = "Custom"
                }
            })
        let cursors = ["block", "bar", "underline"]
        f.popup("Cursor:", cursors.map { $0.capitalized }, cursors.firstIndex(of: s.appearancePreferences.cursor) ?? 0) { i in
            s.updateAppearance { $0.cursor = cursors[i] }
        }
        f.stepper("Scrollback:", s.appearancePreferences.scrollback, 0...1_000_000, suffix: "lines") { v in s.updateAppearance { $0.scrollback = v } }
        f.section("External terminal")
        let installed = ExternalTerminal.installed
        f.popup(
            "Open Terminal Here:",
            ExternalTerminalChoice.allCases.map { $0.title + ($0.bundleID != nil && !installed.contains($0) ? " (not installed)" : "") },
            ExternalTerminalChoice.allCases.firstIndex(of: s.appearancePreferences.externalTerminal) ?? 0
        ) { i in s.updateAppearance { $0.externalTerminal = ExternalTerminalChoice.allCases[i] } }
        f.text("Custom command:", s.appearancePreferences.externalCommand) { [weak f] v in
            do { _ = try TerminalCommandTemplate.expand(v, directory: "/"); s.updateAppearance { $0.externalCommand = v } } catch {
                AppearancePage.show(error); f?.refresh()
            }
        }
        f.note("Use bare {dir} in custom commands; Porpoise quotes the path. Run script appends the quoted script path.")
    }
}
