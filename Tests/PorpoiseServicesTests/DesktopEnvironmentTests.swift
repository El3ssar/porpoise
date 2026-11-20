import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.isolatedSettings) struct DesktopEnvironmentTests {
    private let ready: [String: Any] = [
        "CreateDesktop": true, "StandardHideDesktopIcons": true, "HideDesktop": true,
        "GloballyEnabled": false, "StandardHideWidgets": true, "StageManagerHideWidgets": true,
        "EnableStandardClickToShowDesktop": false,
    ]

    private func inspect(_ values: [String: Any]) -> DesktopEnvironment {
        DesktopEnvironment.inspect { domain, key in
            #expect(domain == (key == "CreateDesktop" ? "com.apple.finder" : "com.apple.WindowManager"))
            return values[key]
        }
    }

    @Test func aHiddenNativeDesktopAndDisabledStageManagerPass() {
        #expect(inspect(ready).isReady)
    }

    @Test func missingPreferencesDoNotAssumeTheNativeDesktopIsHidden() {
        let state = inspect([:])
        #expect(state.conflicts == [.finderItems, .finderStageItems, .widgets, .stageWidgets, .wallpaperClick])
        #expect(!state.isReady)
    }

    @Test func eachConflictingOptionBlocksTheDesktopSeparately() {
        let cases: [(String, Bool, DesktopEnvironment.Conflict)] = [
            ("StandardHideDesktopIcons", false, .finderItems), ("HideDesktop", false, .finderStageItems),
            ("GloballyEnabled", true, .stageManager), ("StandardHideWidgets", false, .widgets),
            ("StageManagerHideWidgets", false, .stageWidgets), ("EnableStandardClickToShowDesktop", true, .wallpaperClick),
        ]
        for (key, value, conflict) in cases {
            var values = ready
            values[key] = value
            #expect(inspect(values).conflicts == [conflict])
        }
    }

    @Test func disablingFinderDoesNotBypassTheStageManagerAndWidgetChecks() {
        var values = ready
        values["CreateDesktop"] = false
        values["StandardHideDesktopIcons"] = false
        values["HideDesktop"] = false
        #expect(inspect(values).isReady)
        values["GloballyEnabled"] = true
        #expect(inspect(values).conflicts == [.stageManager])
        values["StandardHideWidgets"] = false
        #expect(inspect(values).conflicts == [.stageManager, .widgets])
    }

    @Test func unrecognizedTypesAndNumbersFailClosed() {
        for value: Any in ["true", "false", 2, -1, 0.5, NSNull(), [false]] {
            for key in ready.keys {
                var values = ready
                values[key] = value
                #expect(inspect(values).conflicts.contains(.unreadable))
            }
        }
    }

    @Test func aMissingStageManagerOverrideUsesItsOffDefault() {
        var values = ready
        values.removeValue(forKey: "GloballyEnabled")
        #expect(inspect(values).isReady)
    }

    @Test func genericTestsDoNotReadTheRealSystemConfiguration() {
        #expect(Settings.isTesting)
        #expect(DesktopEnvironment.current().conflicts == [.unreadable])
    }

    @Test func isolatedUIFixturesCanChangeAndMalformedOrMissingOnesFailClosed() throws {
        let scratch = try Scratch()
        let path = scratch.path("desktop.json")
        #expect(DesktopEnvironment.fixture(at: path.path, desktopDirectory: scratch.url.path).conflicts == [.unreadable])
        try Data("not JSON".utf8).write(to: path)
        #expect(DesktopEnvironment.fixture(at: path.path, desktopDirectory: scratch.url.path).conflicts == [.unreadable])
        let domains: [String: [String: Any]] = [
            "com.apple.finder": ["CreateDesktop": true], "com.apple.WindowManager": ready.filter { $0.key != "CreateDesktop" },
        ]
        try JSONSerialization.data(withJSONObject: domains).write(to: path)
        #expect(DesktopEnvironment.fixture(at: path.path, desktopDirectory: nil).conflicts == [.unreadable])
        #expect(DesktopEnvironment.fixture(at: path.path, desktopDirectory: "").conflicts == [.unreadable])
        #expect(DesktopEnvironment.fixture(at: path.path, desktopDirectory: scratch.url.path).isReady)
        var changed = domains
        changed["com.apple.WindowManager"]?["GloballyEnabled"] = true
        try JSONSerialization.data(withJSONObject: changed).write(to: path, options: .atomic)
        #expect(DesktopEnvironment.fixture(at: path.path, desktopDirectory: scratch.url.path).conflicts == [.stageManager])
    }

    @Test func preferenceEventsIgnoreUnrelatedAppsAndIncludeAtomicAndPerHostWrites() {
        for path in [
            "/Library/Preferences/com.apple.finder.plist", "/Library/Preferences/com.apple.WindowManager.plist.tmp",
            "/Library/Preferences/ByHost/com.apple.WindowManager.HOST.plist", "/Library/Preferences", "/Library/Preferences/ByHost",
        ] {
            #expect(DesktopEnvironment.isPreferenceChange(path))
        }
        #expect(!DesktopEnvironment.isPreferenceChange("/Library/Preferences/app.porpoise.Porpoise.plist"))
        #expect(!DesktopEnvironment.isPreferenceChange("/Library/Preferences/com.apple.dock.plist"))
    }
}
