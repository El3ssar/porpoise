import AppKit
import PorpoiseCore
import PorpoiseServices
import UniformTypeIdentifiers

/// All edits persist immediately and notify open windows, so the window itself is the preview.
enum AppearancePage {
    static func build(_ f: FormBuilder) {
        let s = Settings.shared
        let themes = [AppearanceTheme.systemName, "Follow system"] + AppearanceTheme.builtIns.map(\.name) + ["Custom"]
        f.grouped = true
        f.section("Theme")
        f.themeCards(
            themes, selected: { s.appearancePreferences.themeName },
            theme: { i in
                if let theme = AppearanceTheme.builtIns.first(where: { $0.name == themes[i] }) { return theme }
                if themes[i] == AppearanceTheme.systemName { return Tokens.palette(dark: Theme.isDark) }
                return s.appearancePreferences.theme(dark: Theme.isDark)
            }
        ) { i in
            s.updateAppearance { p in
                if themes[i] == "Custom", p.customTheme == nil { p.customTheme = Theme.palette(dark: Theme.isDark) }
                p.themeName = themes[i]
            }
        }
        let names = AppearanceTheme.builtIns.map(\.name)
        f.popup("System light theme:", names, names.firstIndex(of: s.appearancePreferences.lightThemeName) ?? 0) { i in
            s.updateAppearance { $0.lightThemeName = names[i] }
        }
        // Only "Follow system" uses these two; under any other theme they would only confuse.
        let followsSystem = { s.appearancePreferences.themeName == "Follow system" }
        f.visibleWhen(followsSystem)
        f.popup("System dark theme:", names, names.firstIndex(of: s.appearancePreferences.darkThemeName) ?? 1) { i in
            s.updateAppearance { $0.darkThemeName = names[i] }
        }
        f.visibleWhen(followsSystem)
        f.popup("Appearance:", AppearanceChoice.allCases.map(\.title), AppearanceChoice.allCases.firstIndex(of: s.appearance) ?? 0) {
            s.appearance = AppearanceChoice.allCases[$0]
        }
        f.button("Import Theme…") {
            readFile(extensions: ["json", "colors"]) { url, data in
                let theme =
                    try url.pathExtension.lowercased() == "colors"
                    ? AppearanceTheme.kde(String(decoding: data, as: UTF8.self), name: url.deletingPathExtension().lastPathComponent)
                    : AppearanceTheme.decode(data)
                s.updateAppearance {
                    $0.customTheme = theme; $0.themeName = "Custom"
                }
            }
        }
        f.button("Export Theme…") { writeFile(name: "Porpoise-theme.json") { try Theme.palette(dark: Theme.isDark).encoded() } }
        f.section("Colors")
        f.note("Changing a color creates a custom theme. Changes preview immediately in open windows.")
        f.colorGrid(
            ThemeRole.allCases.map(\.title),
            values: { index in
                let role = ThemeRole.allCases[index]
                let c = Theme.palette(dark: Theme.isDark)[role]
                return NSColor(rgb: c.red, c.green, c.blue)
            },
            set: { index, color in
                let role = ThemeRole.allCases[index]
                guard let c = color.usingColorSpace(.sRGB) else { return }
                s.updateAppearance { p in
                    if role == .folderTint { p.folderVariant = "default" }
                    var theme = Theme.palette(dark: Theme.isDark)
                    theme[role] = ThemeColor(
                        Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                    theme.name = "Custom"; p.customTheme = theme; p.themeName = "Custom"
                }
            })
        f.section("Icons")
        let icons =
            ["Native macOS", Icons.nativeColourTheme, "Tela-circle"] + IconTheme.bundledThemes
            + IconTheme.installedThemes.filter { !IconTheme.bundledThemes.contains($0) }
        f.popup("Icon theme:", icons, icons.firstIndex(of: s.appearancePreferences.iconTheme) ?? 0) { i in
            s.updateAppearance { $0.iconTheme = icons[i] }
        }
        let variants = ["default", "blue", "green", "red", "orange", "yellow", "purple", "pink", "grey"]
        f.popup(
            "Folder preset:", variants.map { $0 == "default" ? "Use the theme color" : ($0 == "grey" ? "Gray" : $0.capitalized) },
            variants.firstIndex(of: s.appearancePreferences.folderVariant) ?? 0
        ) { i in
            s.updateAppearance { $0.folderVariant = variants[i] }
        }
        f.note(
            "Install freedesktop themes in ~/Library/Application Support/Porpoise/icons, then reopen Settings. Missing icons fall back to Tela-circle."
        )
        f.section("Fonts & Density")
        f.fontPicker("Interface font:", name: s.appearancePreferences.uiFontName, size: s.appearancePreferences.uiFontSize) { name, size in
            s.updateAppearance {
                $0.uiFontName = name; $0.uiFontSize = size
            }
        }
        f.fontPicker("File-list font:", name: s.labelFontName, size: s.labelFontSize) { name, size in
            s.labelFontName = name; s.labelFontSize = size
        }
        f.popup(
            "Density:", ViewDensity.allCases.map { $0.rawValue.capitalized },
            ViewDensity.allCases.firstIndex(of: s.appearancePreferences.density) ?? 1
        ) { i in s.updateAppearance { $0.density = ViewDensity.allCases[i] } }
        // Column view keeps Finder's small icons; its size follows the zoom like the other modes'.
        for mode in ViewMode.allCases where mode != .columns {
            f.stepper(mode.title + " icon size:", iconSize(mode), 8...256, suffix: "pt") { value in
                s.updateAppearance { p in
                    switch mode {
                    case .icons: p.iconsSize = value;
                    case .compact: p.compactSize = value;
                    case .details, .columns: p.detailsSize = value
                    }
                }
                s.applyAppearanceIconSizes()
            }
        }
        f.section("Share all appearance settings")
        f.button("Export Appearance…") { writeFile(name: "Porpoise-appearance.json") { try s.exportAppearance() } }
        f.button("Import Appearance…") {
            readFile(extensions: ["json"]) { _, data in
                // What the file would have terminals run is shown, and taken only if the user says so.
                var commands = false
                let asked = try s.appearanceCommands(in: data)
                if !asked.isEmpty {
                    let a = NSAlert()
                    a.messageText = "This file also sets what the terminal runs"
                    a.informativeText = asked.joined(separator: "\n") + "\n\nUse these only if you trust where the file came from."
                    a.addButton(withTitle: "Keep My Terminal Settings")
                    a.addButton(withTitle: "Use the File's")
                    commands = a.runModal() == .alertSecondButtonReturn
                }
                try s.importAppearance(data, includingCommands: commands); s.applyAppearanceIconSizes()
            }
        }
    }
    private static func iconSize(_ mode: ViewMode) -> Int {
        let p = Settings.shared.appearancePreferences
        switch mode {
        case .icons: return p.iconsSize;
        case .compact: return p.compactSize;
        case .details, .columns: return p.detailsSize
        }
    }
    static func argumentsJSON() -> String {
        String(data: (try? JSONEncoder().encode(Settings.shared.appearancePreferences.shellArguments)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }
    static func show(_ error: Error) { NSAlert(error: error).runModal() }
    static func readFile(extensions: [String], action: (URL, Data) throws -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) };
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try action(url, Data(contentsOf: url)) } catch { show(error) }
    }
    private static func writeFile(name: String, data: () throws -> Data) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data().write(to: url, options: .atomic) } catch { show(error) }
    }
}
