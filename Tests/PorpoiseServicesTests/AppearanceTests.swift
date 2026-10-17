import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseServices

@Suite(.isolatedSettings) struct AppearanceTests {
    @Test func builtInThemesRoundTrip() throws {
        #expect(AppearanceTheme.builtIns.count == 10)
        for theme in AppearanceTheme.builtIns { #expect(try AppearanceTheme.decode(theme.encoded()) == theme) }
    }
    @Test func malformedThemesAreRejected() throws {
        #expect(throws: (any Error).self) { try ThemeColor(hex: "#zz0011") }
        #expect(throws: (any Error).self) { try ThemeColor(hex: "#123") }
        var theme = AppearanceTheme.builtIns[0]
        theme.colors.removeValue(forKey: "text")
        #expect(throws: (any Error).self) { try AppearanceTheme.decode(JSONEncoder().encode(theme)) }
        theme = AppearanceTheme.builtIns[0]; theme.terminalPalette = []
        #expect(throws: (any Error).self) { try theme.validate() }
    }
    @Test func kdeGroupsAndFallbacks() throws {
        let theme = try AppearanceTheme.kde(
            """
            [General]
            Name=Example
            [Colors:Window]
            BackgroundNormal=12,24,36
            [Colors:View]
            BackgroundNormal=1,2,3
            BackgroundAlternate=4,5,6
            ForegroundNormal=220,230,240
            ForegroundInactive=100,110,120
            [Colors:Selection]
            BackgroundNormal=33,66,99
            ForegroundNormal=255,255,255
            """)
        #expect(theme.name == "Example" && theme.isDark)
        #expect(theme[.windowBackground] == ThemeColor(12, 24, 36))
        #expect(theme[.sidebar] == ThemeColor(12, 24, 36))
        #expect(theme[.text] == ThemeColor(220, 230, 240))
        #expect(theme[.alternateRow] == ThemeColor(4, 5, 6))
        #expect(theme[.selection] == ThemeColor(33, 66, 99))
        try theme.validate()
        #expect(throws: (any Error).self) { try AppearanceTheme.kde("[Colors:Window]\nBackgroundNormal=300,0,0") }
        #expect(throws: (any Error).self) { try AppearanceTheme.kde("garbage") }
    }
    @Test func iTermXMLAndBinaryPlists() throws {
        var dictionary: [String: Any] = [:]
        let color: [String: Double] = ["Red Component": 0.5, "Green Component": 0.25, "Blue Component": 1]
        for key in ["Background Color", "Foreground Color"] + (0..<16).map({ "Ansi \($0) Color" }) { dictionary[key] = color }
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
            let palette = try TerminalPalette.iTerm(data)
            #expect(palette.colors.count == 16 && palette.background == ThemeColor(128, 64, 255))
        }
        dictionary["Ansi 4 Color"] = ["Red Component": 2.0, "Green Component": 0, "Blue Component": 0]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        #expect(throws: (any Error).self) { try TerminalPalette.iTerm(data) }
        #expect(throws: (any Error).self) { try TerminalPalette.iTerm(Data("bad".utf8)) }
    }
    @Test func commandTemplateQuotesUntrustedPaths() throws {
        let path = "/tmp/it's a $(touch nope);folder\nnext"
        #expect(
            try TerminalCommandTemplate.expand("kitty --directory {dir}", directory: path)
                == "kitty --directory '/tmp/it'\\''s a $(touch nope);folder\nnext'")
        #expect(throws: (any Error).self) { try TerminalCommandTemplate.expand("kitty", directory: "/tmp") }
        for template in ["kitty \"{dir}\"", "kitty '{dir}'", "kitty ${dir}", "kitty \\{dir}"] {
            #expect(throws: (any Error).self) { try TerminalCommandTemplate.expand(template, directory: path) }
        }
        // Ask an actual shell to round-trip the quoted argument: no substitution may run. The second path's quote
        // carries a combining mark, which makes "'\u{301}" one Character: a Character-based replace left it unescaped.
        for path in [path, "/tmp/x'\u{301}; echo injected #"] {
            let output = try runTool("/bin/sh", ["-c", "printf %s " + TerminalCommandTemplate.quote(path)]).out
            #expect(String(decoding: output, as: UTF8.self) == path)
        }
    }
    @Test func terminalDetectionAndShellResolution() {
        #expect(ExternalTerminalChoice.installed { $0 == "net.kovidgoyal.kitty" } == [.kitty])
        #expect(ExternalTerminalChoice.installed { _ in false }.isEmpty)
        #expect(ShellChoice.login.executable(custom: "", environment: ["SHELL": "/custom/fish"]) == "/custom/fish")
        #expect(ShellChoice.login.executable(custom: "", environment: [:]) == "/bin/zsh")
        #expect(ShellChoice.custom.executable(custom: "/custom/nu") == "/custom/nu")
        #expect(
            ShellChoice.fish.executable(custom: "", environment: [:], isExecutable: { $0 == "/opt/homebrew/bin/fish" }) == "/opt/homebrew/bin/fish")
        #expect(ShellChoice.nu.arguments == ["--login"])
    }
    @Test func persistenceExportImportAndReset() throws {
        let s = Settings.shared
        s.updateAppearance { p in
            p.themeName = "Nord"; p.shell = .fish; p.density = .comfortable
            p.customTheme = AppearanceTheme.builtIns[3]
            p.shellArguments = ["-l", "a b"]; p.externalTerminal = .kitty; p.uiFontName = "Menlo"
        }
        s.labelFontName = "Monaco"; s.labelFontSize = 15; s.appearance = .dark
        let exported = try s.exportAppearance()
        s.resetAll()
        #expect(s.appearancePreferences.themeName == "Follow system")
        try s.importAppearance(exported, includingCommands: true)
        #expect(s.appearancePreferences.themeName == "Nord")
        #expect(s.appearancePreferences.shell == .fish)
        #expect(s.labelFontName == "Monaco" && s.labelFontSize == 15 && s.appearance == .dark)
        #expect(s.appearancePreferences.customTheme == AppearanceTheme.builtIns[3])
        #expect(s.appearancePreferences.externalTerminal == .kitty)
        #expect(try s.exportAppearance() == exported)
    }
    @Test func legacyExternalTerminalPreferenceIsPreserved() {
        Settings.store.set("net.kovidgoyal.kitty", forKey: "terminalApp")
        #expect(Settings.shared.appearancePreferences.externalTerminal == .kitty)
        Settings.shared.updateAppearance { $0.externalTerminal = .terminal }
        #expect(Settings.shared.appearancePreferences.externalTerminal == .terminal)
    }

    @Test func invalidAppearanceImportIsAtomic() throws {
        let s = Settings.shared
        s.updateAppearance { $0.themeName = "Nord" }
        var invalid = s.appearancePreferences; invalid.uiFontSize = 10000
        #expect(throws: (any Error).self) { try s.importAppearance(JSONEncoder().encode(invalid)) }
        #expect(s.appearancePreferences.themeName == "Nord")
        invalid = s.appearancePreferences; invalid.version = 99
        #expect(throws: (any Error).self) { try s.importAppearance(JSONEncoder().encode(invalid)) }
    }
    @Test func followsSystemPairAndFixedThemes() {
        var p = AppearancePreferences()
        #expect(p.theme(dark: false).name == "Breeze Light")
        #expect(p.theme(dark: true).name == "Breeze Dark")
        p.darkThemeName = "Nord"
        #expect(p.theme(dark: true).name == "Nord")
        p.themeName = "Dracula"
        #expect(p.theme(dark: false).name == "Dracula")
        p.themeName = "unknown"
        #expect(p.theme(dark: false).name == "Breeze Light")
    }
    @Test func iconLookupRejectsTraversalAndFallsBack() {
        Settings.shared.updateAppearance { $0.iconTheme = "missing theme" }
        #expect(IconTheme.shared.file("../secret", size: 22) == nil)
        #expect(IconTheme.shared.file("folder", size: 64) != nil)
        #expect(IconTheme.shared.file("definitely-unknown-porpoise-icon", size: 64) == nil)
    }
}
