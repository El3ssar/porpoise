import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseServices

/// How appearance preferences are stored: what a stored value written elsewhere reads as, what a broken one falls
/// back to, which writes are refused, and how the icon sizes reach the view properties.
@Suite(.isolatedSettings) struct AppearanceSettingsCoverageTests {
    /// Collects the `Settings.changed` objects posted while `body` runs (posting is synchronous).
    private func changes(_ body: () throws -> Void) rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: nil) { note in
            if let name = note.object as? String, name.hasPrefix("appearance") { seen.append(name) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try body()
        return seen
    }

    @Test func storedValueWrittenElsewhereIsReadAndCached() throws {
        var stored = AppearancePreferences()
        stored.themeName = "Gruvbox"; stored.scrollback = 42; stored.cursor = "bar"
        Settings.store.set(try JSONEncoder().encode(stored), forKey: "appearancePreferences")
        #expect(Settings.shared.appearancePreferences == stored)
        #expect(Settings.shared.appearancePreferences == stored)  // the second read comes from the cache
        stored.themeName = "Nord"
        Settings.store.set(try JSONEncoder().encode(stored), forKey: "appearancePreferences")
        #expect(Settings.shared.appearancePreferences.themeName == "Nord")
    }

    @Test func brokenOrInvalidStoredValueFallsBackToDefaults() throws {
        Settings.store.set(Data("not json".utf8), forKey: "appearancePreferences")
        #expect(Settings.shared.appearancePreferences == AppearancePreferences())
        var invalid = AppearancePreferences(); invalid.themeName = "Nord"; invalid.cursor = "beam"
        Settings.store.set(try JSONEncoder().encode(invalid), forKey: "appearancePreferences")
        #expect(Settings.shared.appearancePreferences == AppearancePreferences())
        // A stored value, even a broken one, wins over the legacy terminal key.
        Settings.store.set("net.kovidgoyal.kitty", forKey: "terminalApp")
        #expect(Settings.shared.appearancePreferences.externalTerminal == .automatic)
    }

    @Test func unknownLegacyTerminalKeepsAutomatic() {
        Settings.store.set("com.example.unknown-terminal", forKey: "terminalApp")
        #expect(Settings.shared.appearancePreferences.externalTerminal == .automatic)
        Settings.store.set("com.googlecode.iterm2", forKey: "terminalApp")
        #expect(Settings.shared.appearancePreferences.externalTerminal == .iTerm)
    }

    @Test func invalidWritesAreRefusedSilently() {
        let s = Settings.shared
        let accepted = changes { s.updateAppearance { $0.themeName = "Dracula" } }
        #expect(accepted == ["appearancePreferences"])
        let refused = changes {
            s.updateAppearance { $0.iconsSize = 4 }
            s.updateAppearance {
                $0.externalTerminal = .custom; $0.externalCommand = "open -a Terminal"
            }
            var p = s.appearancePreferences; p.version = 7; s.appearancePreferences = p
        }
        #expect(refused.isEmpty)
        #expect(s.appearancePreferences.themeName == "Dracula" && s.appearancePreferences.iconsSize == 64)
        #expect(s.appearancePreferences.externalTerminal == .automatic)
    }

    @Test func iconSizesReachTheViewPropertiesClamped() {
        let s = Settings.shared
        s.updateAppearance {
            $0.iconsSize = 96; $0.compactSize = 8; $0.detailsSize = 512
        }
        let posted = changes { s.applyAppearanceIconSizes() }
        #expect(posted == ["appearanceIconSizes"])
        let properties = s.globalViewProperties
        #expect(properties.iconSize(for: .icons) == 96)
        #expect(properties.iconSize(for: .compact) == ZoomLevels.minSize)
        #expect(properties.iconSize(for: .details) == ZoomLevels.maxSize)
        s.updateAppearance { $0.iconsSize = 48 }
        s.applyAppearanceIconSizes()
        #expect(s.globalViewProperties.iconSize(for: .icons) == 48 && s.globalViewProperties.iconSize(for: .compact) == ZoomLevels.minSize)
    }

    @Test func exportCarriesWindowAppearanceAndFileFont() throws {
        let s = Settings.shared
        s.appearance = .light; s.labelFontName = "Menlo"; s.labelFontSize = 11
        let exported = try JSONDecoder().decode(AppearancePreferences.self, from: s.exportAppearance())
        #expect(exported.appearance == "light" && exported.fileFontName == "Menlo" && exported.fileFontSize == 11)
        // The stored preferences themselves are not changed by exporting.
        #expect(s.appearancePreferences.appearance == "system")
        let text = String(decoding: try s.exportAppearance(), as: UTF8.self)
        #expect(text.contains("\n") && text.range(of: "\"appearance\"")!.lowerBound < text.range(of: "\"version\"")!.lowerBound)
    }

    @Test func importRejectsMalformedFilesAndKeepsSettings() throws {
        let s = Settings.shared
        s.updateAppearance { $0.themeName = "Nord" }
        s.labelFontName = "Monaco"
        for data in [Data(), Data("{".utf8), Data(#"{"version":"one"}"#.utf8), Data("[]".utf8)] {
            #expect(throws: (any Error).self) { try s.importAppearance(data) }
        }
        var badCommand = AppearancePreferences(); badCommand.externalTerminal = .custom; badCommand.externalCommand = "x '{dir}'"
        #expect(throws: AppearanceError.self) { try s.importAppearance(JSONEncoder().encode(badCommand), includingCommands: true) }
        #expect(s.appearancePreferences.themeName == "Nord" && s.labelFontName == "Monaco")
        var good = AppearancePreferences(); good.appearance = "light"; good.fileFontName = "Courier"; good.fileFontSize = 20
        try s.importAppearance(JSONEncoder().encode(good))
        #expect(s.appearance == .light && s.labelFontName == "Courier" && s.labelFontSize == 20)
        #expect(s.appearancePreferences == good)
    }
}
