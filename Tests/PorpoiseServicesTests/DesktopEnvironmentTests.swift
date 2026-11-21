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

    @Test func aHiddenNativeDesktopPasses() {
        #expect(inspect(ready).isReady)
    }

    @Test func stageManagerAndTheWallpaperClickAreTheUsersChoice() {
        for stage in [false, true] {
            for click in [false, true] {
                var values = ready
                values["GloballyEnabled"] = stage
                values["EnableStandardClickToShowDesktop"] = click
                #expect(inspect(values).isReady)
            }
        }
    }

    @Test func missingPreferencesDoNotAssumeTheNativeDesktopIsHidden() {
        let state = inspect([:])
        #expect(state.conflicts == [.finderItems, .finderStageItems, .widgets, .stageWidgets])
        #expect(!state.isReady)
    }

    @Test func eachConflictingOptionBlocksTheDesktopSeparately() {
        let cases: [(String, Bool, DesktopEnvironment.Conflict)] = [
            ("StandardHideDesktopIcons", false, .finderItems), ("HideDesktop", false, .finderStageItems),
            ("StandardHideWidgets", false, .widgets), ("StageManagerHideWidgets", false, .stageWidgets),
        ]
        for (key, value, conflict) in cases {
            var values = ready
            values[key] = value
            #expect(inspect(values).conflicts == [conflict])
        }
    }

    @Test func disablingFinderDoesNotBypassTheWidgetChecks() {
        var values = ready
        values["CreateDesktop"] = false
        values["StandardHideDesktopIcons"] = false
        values["HideDesktop"] = false
        #expect(inspect(values).isReady)
        values["StandardHideWidgets"] = false
        #expect(inspect(values).conflicts == [.widgets])
    }

    @Test func aClickRevealsTheDesktopAsTheWallpaperSettingSays() {
        func reveals(_ values: [String: Any]) -> Bool {
            DesktopEnvironment.clickRevealsDesktop(DesktopPreferences(read: { values[$1] }, write: { _, _, _ in }))
        }
        #expect(reveals([:]))  // macOS's default: Always
        #expect(reveals(["EnableStandardClickToShowDesktop": true, "GloballyEnabled": false]))
        #expect(!reveals(["EnableStandardClickToShowDesktop": false, "GloballyEnabled": false]))
        #expect(reveals(["EnableStandardClickToShowDesktop": false, "GloballyEnabled": true]))
        #expect(!reveals(["EnableStandardClickToShowDesktop": "yes"]))
    }

    /// An in-memory stand-in for both preference domains, recording every write.
    private final class FakePreferences {
        var domains: [String: [String: Any]]
        var writes: [(String, Any?)] = []
        var syncs = 0
        init(_ windowManager: [String: Any], finder: [String: Any] = [:]) {
            domains = ["com.apple.WindowManager": windowManager, "com.apple.finder": finder]
        }
        lazy var preferences = DesktopPreferences(
            read: { [unowned self] in domains[$0]?[$1] },
            write: { [unowned self] domain, key, value in
                domains[domain, default: [:]][key] = value
                writes.append((key, value))
            },
            synchronize: { [unowned self] in syncs += 1; return true })
        func value(_ key: String) -> Any? { domains["com.apple.WindowManager"]?[key] }
    }

    private func isolatedStore() throws -> UserDefaults {
        let name = "DesktopSystemSettingsTests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func applyingHidesFinderItemsAndWidgetsAndRestoringPutsBackWhatTheUserHad() throws {
        let fake = FakePreferences(["StandardHideDesktopIcons": false, "HideDesktop": true, "GloballyEnabled": true])
        let store = try isolatedStore()
        let settings = DesktopSystemSettings(preferences: fake.preferences, store: store)
        settings.apply()
        for key in DesktopSystemSettings.hiddenKeys { #expect(fake.value(key) as? Bool == true, "\(key)") }
        #expect(DesktopEnvironment.inspect(fake.preferences).isReady)
        // Stage Manager is never touched; a key already hidden isn't recorded or rewritten.
        #expect(fake.value("GloballyEnabled") as? Bool == true)
        #expect(Set(fake.writes.map(\.0)) == ["StandardHideDesktopIcons", "StandardHideWidgets", "StageManagerHideWidgets"])
        #expect(Set(settings.saved.keys) == ["StandardHideDesktopIcons", "StandardHideWidgets", "StageManagerHideWidgets"])
        settings.restore()
        #expect(fake.value("StandardHideDesktopIcons") as? Bool == false)
        #expect(fake.value("HideDesktop") as? Bool == true)
        // Keys that weren't set before are removed again, so macOS uses its own defaults.
        #expect(fake.value("StandardHideWidgets") == nil && fake.value("StageManagerHideWidgets") == nil)
        #expect(settings.saved.isEmpty && store.object(forKey: DesktopSystemSettings.savedKey) == nil)
    }

    @Test func applyingAgainAfterACrashKeepsTheFirstOriginals() throws {
        let fake = FakePreferences(["StandardHideDesktopIcons": false])
        let store = try isolatedStore()
        DesktopSystemSettings(preferences: fake.preferences, store: store).apply()
        // A new session (the previous one never restored) finds the settings hidden and must not record that as original.
        let next = DesktopSystemSettings(preferences: fake.preferences, store: store)
        next.apply()
        #expect((next.saved["StandardHideDesktopIcons"]?["value"] as? Bool) == false)
        // Something else showed the items again meanwhile: hidden again, still with the user's first value recorded.
        fake.domains["com.apple.WindowManager"]?["StandardHideDesktopIcons"] = false
        next.apply()
        #expect(fake.value("StandardHideDesktopIcons") as? Bool == true)
        next.restore()
        #expect(fake.value("StandardHideDesktopIcons") as? Bool == false)
    }

    @Test func restoringLeavesAValueTheUserChangedThemselves() throws {
        let fake = FakePreferences([:])
        let store = try isolatedStore()
        let settings = DesktopSystemSettings(preferences: fake.preferences, store: store)
        settings.apply()
        fake.domains["com.apple.WindowManager"]?["StandardHideWidgets"] = false  // shown again in System Settings
        settings.restore()
        #expect(fake.value("StandardHideWidgets") as? Bool == false)
        #expect(fake.value("HideDesktop") == nil)
        // Nothing recorded: restoring writes nothing at all.
        fake.writes = []
        settings.restore()
        #expect(fake.writes.isEmpty)
    }

    @Test func withFindersDesktopOffOnlyTheWidgetsAreHidden() throws {
        let fake = FakePreferences([:], finder: ["CreateDesktop": false])
        let settings = DesktopSystemSettings(preferences: fake.preferences, store: try isolatedStore())
        settings.apply()
        #expect(Set(fake.writes.map(\.0)) == ["StandardHideWidgets", "StageManagerHideWidgets"])
        #expect(DesktopEnvironment.inspect(fake.preferences).isReady)
    }

    @Test func aWatcherRestoresOnlyForTheProcessThatLastAppliedThem() throws {
        let fake = FakePreferences(["StandardHideDesktopIcons": false])
        let store = try isolatedStore()
        let settings = DesktopSystemSettings(preferences: fake.preferences, store: store)
        settings.apply(owner: 100)
        // Porpoise crashed and was relaunched (pid 200) before its old watcher got to restore.
        settings.apply(owner: 200)
        settings.restore(onlyFor: 100)
        #expect(fake.value("StandardHideDesktopIcons") as? Bool == true && !settings.saved.isEmpty)
        settings.restore(onlyFor: 200)
        #expect(fake.value("StandardHideDesktopIcons") as? Bool == false && settings.saved.isEmpty)
        #expect(store.object(forKey: DesktopSystemSettings.ownerKey) == nil)
    }

    @Test func genericTestsGetNoSystemPreferencesToChange() {
        #expect(DesktopPreferences.current() == nil && DesktopSystemSettings.current() == nil)
    }

    @Test func unrecognizedTypesAndNumbersFailClosed() {
        for value: Any in ["true", "false", 2, -1, 0.5, NSNull(), [false]] {
            // Stage Manager and the wallpaper click don't decide whether the desktop can start.
            for key in ready.keys where key != "GloballyEnabled" && key != "EnableStandardClickToShowDesktop" {
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
        changed["com.apple.WindowManager"]?["StandardHideWidgets"] = false
        try JSONSerialization.data(withJSONObject: changed).write(to: path, options: .atomic)
        #expect(DesktopEnvironment.fixture(at: path.path, desktopDirectory: scratch.url.path).conflicts == [.widgets])
        // Desktop Mode writes into the fixture as it would into macOS, keeping the rest of it.
        let preferences = try #require(DesktopPreferences.fixture(at: path.path, desktopDirectory: scratch.url.path))
        preferences.write("com.apple.WindowManager", "StandardHideWidgets", true)
        #expect(DesktopEnvironment.fixture(at: path.path, desktopDirectory: scratch.url.path).isReady)
        preferences.write("com.apple.WindowManager", "StandardHideWidgets", nil)
        #expect(preferences.read("com.apple.WindowManager", "StandardHideWidgets") == nil)
        #expect(preferences.read("com.apple.finder", "CreateDesktop") as? Bool == true)
    }

    @Test func disksAreSortedIntoFindersDesktopChoices() {
        #expect(DesktopVolumes.kind(isLocal: false, fileSystem: "smbfs", isInternal: false) == .server)
        #expect(DesktopVolumes.kind(isLocal: true, fileSystem: "cd9660", isInternal: false) == .removableMedia)
        #expect(DesktopVolumes.kind(isLocal: true, fileSystem: "UDF", isInternal: nil) == .removableMedia)
        #expect(DesktopVolumes.kind(isLocal: true, fileSystem: "apfs", isInternal: true) == .hardDisk)
        // USB drives, cards and disk images (macOS calls these removable too) are external disks, as in Finder.
        #expect(DesktopVolumes.kind(isLocal: true, fileSystem: "hfs", isInternal: nil) == .externalDisk)
        #expect(DesktopVolumes.kind(isLocal: true, fileSystem: "msdos", isInternal: false) == .externalDisk)
        #expect(DesktopVolumes.kind(isLocal: nil, fileSystem: nil, isInternal: nil) == .externalDisk)
        // Finder's defaults: external disks and removable media, not the internal disk or servers.
        let defaults = DesktopVolumes.Shown.finder(nil)
        #expect(!defaults.includes(.hardDisk) && defaults.includes(.externalDisk) && defaults.includes(.removableMedia))
        #expect(!defaults.includes(.server))
        let finder = DesktopPreferences(
            read: { domain, key in
                domain == "com.apple.finder" ? ["ShowHardDrivesOnDesktop": true, "ShowExternalHardDrivesOnDesktop": false][key] : nil
            }, write: { _, _, _ in })
        let shown = DesktopVolumes.Shown.finder(finder)
        #expect(shown.includes(.hardDisk) && !shown.includes(.externalDisk) && shown.includes(.removableMedia))
    }

    @Test func theStartupDiskIsListedOnlyWhenHardDisksAreShown() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let listed = DesktopVolumes.items(shown: .init(hardDisks: true), volumes: [root])
        #expect(listed.count == 1 && listed.first?.url == root && listed.first?.isDirectory == true)
        #expect(listed.first?.name.isEmpty == false && listed.first?.name != "/")
        #expect(DesktopVolumes.items(shown: .init(hardDisks: false), volumes: [root]).isEmpty)
    }

    @Test func onlyADisksTopLevelCountsAsADisk() throws {
        let scratch = try Scratch()
        #expect(DesktopVolumes.isVolume(URL(fileURLWithPath: "/")))
        #expect(!DesktopVolumes.isVolume(scratch.url))
        #expect(!DesktopVolumes.isVolume(URL(fileURLWithPath: "/Volumes")))
        #expect(!DesktopVolumes.isVolume(URL(fileURLWithPath: "/Volumes/Not mounted here")))
        #expect(!DesktopVolumes.isVolume(URL(string: "sftp://host/")!))
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
