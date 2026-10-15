import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

/// Pure appearance models: colour parsing, theme and terminal-scheme parsers, titles shown in Settings and the
/// fallbacks used when a file leaves something out.
struct AppearanceCoverageTests {
    @Test func themeColorParsesClampsAndRoundTrips() throws {
        #expect(try ThemeColor(hex: "#A0b1C2") == ThemeColor(160, 177, 194))
        #expect(try ThemeColor(hex: "a0b1c2").hex == "#a0b1c2")
        #expect(ThemeColor(-5, 300, 128) == ThemeColor(0, 255, 128))
        for bad in ["", "#", "#12345", "#1234567", "#12 456", "#+12345", "12345g"] {
            #expect(throws: AppearanceError.self) { try ThemeColor(hex: bad) }
        }
        let encoded = try JSONEncoder().encode([ThemeColor(1, 2, 3)])
        #expect(String(decoding: encoded, as: UTF8.self) == ##"["#010203"]"##)
        #expect(try JSONDecoder().decode([ThemeColor].self, from: encoded) == [ThemeColor(1, 2, 3)])
        #expect(throws: (any Error).self) { try JSONDecoder().decode([ThemeColor].self, from: Data(#"["red"]"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode([ThemeColor].self, from: Data("[42]".utf8)) }
    }

    @Test func everyErrorExplainsItself() {
        let errors: [AppearanceError] = [.invalidColor("#xyz"), .invalidTheme, .invalidTerminalScheme, .invalidTemplate]
        let messages = errors.map { $0.errorDescription ?? "" }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == errors.count)
        #expect(messages[0].contains("#xyz"))
        #expect(AppearanceError.invalidTemplate.localizedDescription.contains("{dir}"))
    }

    @Test func rolesAndChoicesHaveDistinctTitles() {
        let roles = ThemeRole.allCases.map(\.title)
        #expect(roles.count == 12 && Set(roles).count == roles.count && roles.allSatisfy { !$0.isEmpty })
        #expect(ThemeRole.sidebar.title == "Places sidebar")
        let terminals = ExternalTerminalChoice.allCases.map(\.title)
        #expect(Set(terminals).count == terminals.count)
        #expect(ExternalTerminalChoice.iTerm.title == "iTerm2" && ExternalTerminalChoice.custom.title == "Custom command")
        #expect(ExternalTerminalChoice.automatic.bundleID == nil && ExternalTerminalChoice.custom.bundleID == nil)
        let bundleIDs = ExternalTerminalChoice.allCases.compactMap(\.bundleID)
        #expect(bundleIDs.count == 7 && Set(bundleIDs).count == 7)
        #expect(ShellChoice.login.title == "Login shell" && ShellChoice.custom.title == "Custom" && ShellChoice.fish.title == "fish")
        #expect(ShellChoice.zsh.arguments == ["-l"] && ShellChoice.custom.arguments.isEmpty)
        #expect(ViewDensity.compact.padding < ViewDensity.normal.padding && ViewDensity.normal.padding < ViewDensity.comfortable.padding)
    }

    @Test func shellResolutionSearchesPathAndFallsBack() throws {
        // The real file check: /bin/zsh ships with macOS and comes first.
        #expect(ShellChoice.zsh.executable(custom: "", environment: ["PATH": "/nonexistent"]) == "/bin/zsh")
        let scratch = try Scratch()
        let bin = try scratch.folder("bin")
        let checked = ShellChoice.bash.executable(custom: "", environment: ["PATH": bin.path + ":/elsewhere"]) { _ in false }
        #expect(checked == "/bin/bash")
        var seen: [String] = []
        _ = ShellChoice.fish.executable(custom: "", environment: ["PATH": bin.path]) {
            seen.append($0); return false
        }
        #expect(seen == ["/bin/fish", "/opt/homebrew/bin/fish", "/usr/local/bin/fish", bin.path + "/fish"])
        let found = ShellChoice.nu.executable(custom: "", environment: ["PATH": "/a:" + bin.path]) { $0 == bin.path + "/nu" }
        #expect(found == bin.path + "/nu")
    }

    @Test func builtInThemesHaveEveryRoleAndTheirOwnPalette() throws {
        for theme in AppearanceTheme.builtIns {
            try theme.validate()
            for role in ThemeRole.allCases { #expect(theme.colors[role.rawValue] != nil) }
        }
        #expect(Set(AppearanceTheme.builtIns.map(\.name)).count == AppearanceTheme.builtIns.count)
        let byName = Dictionary(uniqueKeysWithValues: AppearanceTheme.builtIns.map { ($0.name, $0) })
        #expect(try byName["Nord"]?.terminalPalette.first == ThemeColor(hex: "3b4252"))
        #expect(byName["Breeze Light"]?[.selection] == ThemeColor(66, 132, 210))
        #expect(byName["Breeze Dark"]?[.selection] == ThemeColor(71, 99, 130))
        #expect(byName["High Contrast"]?[.selectionText] == ThemeColor(0, 0, 0))
        #expect(byName["Breeze Light"]?.isDark == false && byName["Breeze Dark"]?.isDark == true)
    }

    @Test func missingRoleReadsBlackAndBlankNameIsRejected() throws {
        var theme = AppearanceTheme.builtIns[2]
        theme.colors.removeValue(forKey: ThemeRole.hover.rawValue)
        #expect(theme[.hover] == ThemeColor(0, 0, 0))
        #expect(throws: AppearanceError.self) { try theme.encoded() }
        theme[.hover] = ThemeColor(9, 9, 9)
        #expect(try AppearanceTheme.decode(theme.encoded())[.hover] == ThemeColor(9, 9, 9))
        theme.name = " \n\t"
        #expect(throws: AppearanceError.self) { try theme.validate() }
        #expect(throws: (any Error).self) { try AppearanceTheme.decode(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try AppearanceTheme.decode(Data("not json".utf8)) }
    }

    @Test func kdeParserSkipsCommentsJunkAndUnknownGroups() throws {
        let theme = try AppearanceTheme.kde(
            """
            # a comment
            ; another comment
            [General]
            Name=
            ColorScheme=Ignored
            [Colors:Window]
            BackgroundNormal = 240 , 240 , 240
            [Colors:Header]
            BackgroundNormal=1,1,1
            [Colors:View]
            ForegroundNormal=10,20
            ForegroundInactive=a,b,c
            DecorationHover=5,6,7,255
            BackgroundAlternate=-1,0,0
            no equals sign here
            [WM]
            activeBackground=9,9,9
            """, name: "Fallback name")
        #expect(theme.name == "Fallback name" && !theme.isDark)
        let light = AppearanceTheme.builtIns[0]
        #expect(theme[.windowBackground] == ThemeColor(240, 240, 240) && theme[.panel] == ThemeColor(240, 240, 240))
        #expect(theme[.hover] == ThemeColor(5, 6, 7))
        // Malformed or out-of-range values keep the Breeze defaults.
        #expect(theme[.text] == light[.text] && theme[.secondaryText] == light[.secondaryText])
        #expect(theme[.alternateRow] == light[.alternateRow] && theme[.selection] == light[.selection])
        #expect(theme.terminalPalette == light.terminalPalette)
        try theme.validate()
    }

    @Test func kdeViewBackgroundAloneDecidesDarkness() throws {
        let dark = try AppearanceTheme.kde("[Colors:View]\nBackgroundNormal=20,20,20")
        #expect(dark.isDark && dark.name == "Imported KDE theme")
        #expect(dark[.viewBackground] == ThemeColor(20, 20, 20))
        #expect(dark[.windowBackground] == AppearanceTheme.builtIns[1][.windowBackground])
        let edge = try AppearanceTheme.kde("[Colors:View]\nBackgroundNormal=128,128,128")
        #expect(!edge.isDark)
        #expect(throws: AppearanceError.self) { try AppearanceTheme.kde("") }
        #expect(throws: AppearanceError.self) { try AppearanceTheme.kde("[Colors:Selection]\nBackgroundNormal=1,2,3") }
    }

    @Test func konsoleSchemesUseTheirColoursOrFallBack() {
        var text = "[Background]\nColor=1,2,3\n[Foreground]\nColor=250,251,252\n"
        for i in 0..<8 { text += "[Color\(i)]\nColor=\(i),0,0\n[Color\(i)Intense]\nColor=\(i),1,1\n" }
        let full = TerminalPalette.konsole(text, name: "Mine")
        #expect(full.name == "Mine" && full.background == ThemeColor(1, 2, 3) && full.foreground == ThemeColor(250, 251, 252))
        #expect(full.colors.count == 16 && full.colors[3] == ThemeColor(3, 0, 0) && full.colors[11] == ThemeColor(3, 1, 1))
        let empty = TerminalPalette.konsole("garbage", name: "Empty")
        #expect(empty.background == ThemeColor(29, 33, 47) && empty.foreground == ThemeColor(214, 219, 241))
        #expect(empty.colors == KonsoleScheme.builtInDesertPalette.map { ThemeColor($0.0, $0.1, $0.2) })
        // Only some colours: the whole palette stays the built-in one.
        let partial = TerminalPalette.konsole("[Color0]\nColor=9,9,9\n", name: "Partial")
        #expect(partial.colors == empty.colors)
    }

    @Test func builtInTerminalPalettesFollowTheThemes() throws {
        let palettes = TerminalPalette.builtIns
        #expect(palettes.map(\.name) == AppearanceTheme.builtIns.map(\.name))
        for (palette, theme) in zip(palettes, AppearanceTheme.builtIns) {
            #expect(palette.colors.count == 16 && palette.background == theme[.windowBackground] && palette.foreground == theme[.text])
        }
        let copy = try JSONDecoder().decode(TerminalPalette.self, from: JSONEncoder().encode(palettes[3]))
        #expect(copy == palettes[3])
    }

    @Test func iTermSchemesWithMissingOrBrokenColoursAreRejected() throws {
        let good: [String: Double] = ["Red Component": 0, "Green Component": 0.5, "Blue Component": 1]
        var dictionary: [String: Any] = [:]
        for key in ["Background Color", "Foreground Color"] + (0..<16).map({ "Ansi \($0) Color" }) { dictionary[key] = good }
        func data(_ d: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0) }
        let palette = try TerminalPalette.iTerm(data(dictionary), name: "Custom")
        #expect(palette.name == "Custom" && palette.foreground == ThemeColor(0, 128, 255))
        for broken: Any in [
            "not a dictionary", ["Red Component": 0.1, "Green Component": 0.2] as [String: Double],
            ["Red Component": Double.nan, "Green Component": 0, "Blue Component": 0] as [String: Double],
            ["Red Component": "1", "Green Component": "0", "Blue Component": "0"],
        ] {
            var copy = dictionary; copy["Ansi 15 Color"] = broken
            #expect(throws: AppearanceError.self) { try TerminalPalette.iTerm(data(copy)) }
        }
        var missing = dictionary; missing.removeValue(forKey: "Foreground Color")
        #expect(throws: AppearanceError.self) { try TerminalPalette.iTerm(data(missing)) }
        #expect(throws: AppearanceError.self) { try TerminalPalette.iTerm(data(["a", "b"])) }
    }

    @Test func commandTemplatesHandleEscapesQuotesAndRepeats() throws {
        #expect(try TerminalCommandTemplate.expand("{dir}", directory: "/a b") == "'/a b'")
        #expect(try TerminalCommandTemplate.expand("cd {dir} && ls {dir}", directory: "/x") == "cd '/x' && ls '/x'")
        // A quoted part elsewhere, an escaped quote and a backslash inside single quotes are all fine.
        #expect(try TerminalCommandTemplate.expand(#"echo "hi" \' 'a\' {dir}"#, directory: "/x") == #"echo "hi" \' 'a\' '/x'"#)
        #expect(try TerminalCommandTemplate.expand(#"say "it's" {dir}"#, directory: "/x") == #"say "it's" '/x'"#)
        for template in [#"open "{dir}"#, "open 'x {dir}", "open $({dir})x\"", "open $({dir}) '", "a \\\\{dir}x \\"] {
            #expect(throws: AppearanceError.self) { try TerminalCommandTemplate.expand(template, directory: "/x") }
        }
        // An escaped brace hides one placeholder from the scan, so the counts no longer agree.
        #expect(throws: AppearanceError.self) { try TerminalCommandTemplate.expand("a \\{dir} {dir}", directory: "/x") }
        #expect(TerminalCommandTemplate.quote("") == "''" && TerminalCommandTemplate.quote("'") == #"''\'''"#)
    }

    @Test func preferencesValidateEveryLimit() throws {
        try AppearancePreferences().validate()
        let invalid: [(inout AppearancePreferences) -> Void] = [
            { $0.version = 2 }, { $0.uiFontSize = 5 }, { $0.fileFontSize = .infinity }, { $0.terminalFontSize = .nan },
            { $0.iconsSize = 7 }, { $0.compactSize = 513 }, { $0.detailsSize = 0 }, { $0.scrollback = -1 },
            { $0.scrollback = 1_000_001 }, { $0.cursor = "beam" }, { $0.appearance = "sepia" },
            {
                var t = AppearanceTheme.builtIns[0]; t.terminalPalette.removeLast(); $0.customTheme = t
            },
            { $0.customTerminalPalette = TerminalPalette(name: "x", background: .init(0, 0, 0), foreground: .init(1, 1, 1), colors: []) },
            {
                $0.externalTerminal = .custom; $0.externalCommand = "open -a Terminal"
            },
            {
                $0.externalTerminal = .custom; $0.externalCommand = "open '{dir}'"
            },
        ]
        for change in invalid {
            var p = AppearancePreferences(); change(&p)
            #expect(throws: AppearanceError.self) { try p.validate() }
        }
        var valid = AppearancePreferences()
        valid.externalTerminal = .custom; valid.externalCommand = "wezterm start --cwd {dir}"
        valid.customTerminalPalette = TerminalPalette.builtIns[0]; valid.customTheme = AppearanceTheme.builtIns[4]
        valid.cursor = "underline"; valid.appearance = "dark"; valid.scrollback = 0; valid.iconsSize = 512
        try valid.validate()
        #expect(try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(valid)) == valid)
        // A custom command is only checked when the custom terminal is chosen.
        var other = AppearancePreferences(); other.externalCommand = "no placeholder"
        try other.validate()
    }

    @Test func customThemeIsUsedOnlyWhenChosen() {
        var p = AppearancePreferences()
        var custom = AppearanceTheme.builtIns[6]; custom.name = "Mine"
        p.customTheme = custom
        #expect(p.theme(dark: true).name == "Breeze Dark")
        p.themeName = "Custom"
        #expect(p.theme(dark: false) == custom && p.theme(dark: true) == custom)
        p.customTheme = nil
        #expect(p.theme(dark: true).name == "Breeze Dark" && p.theme(dark: false).name == "Breeze Light")
        p.themeName = "Follow system"; p.lightThemeName = "gone"; p.darkThemeName = "Gruvbox"
        #expect(p.theme(dark: false).name == "Breeze Light" && p.theme(dark: true).name == "Gruvbox")
    }
}
