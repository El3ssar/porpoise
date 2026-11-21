import CoreFoundation
import Foundation

/// The macOS desktop preferences Desktop Mode reads and changes: the system's own (CoreFoundation preferences), or a UI
/// test's JSON stand-in. These keys are not a public configuration API: unrecognized values fail closed.
public final class DesktopPreferences: @unchecked Sendable {
    public static let finder = "com.apple.finder"
    public static let windowManager = "com.apple.WindowManager"

    private let reader: (_ domain: String, _ key: String) -> Any?
    private let writer: (_ domain: String, _ key: String, _ value: Any?) -> Void
    private let synchronizer: () -> Bool

    public init(
        read: @escaping (_ domain: String, _ key: String) -> Any?, write: @escaping (_ domain: String, _ key: String, _ value: Any?) -> Void,
        synchronize: @escaping () -> Bool = { true }
    ) {
        reader = read
        writer = write
        synchronizer = synchronize
    }

    public func read(_ domain: String, _ key: String) -> Any? { reader(domain, key) }
    /// nil removes the key, so macOS uses its default again.
    public func write(_ domain: String, _ key: String, _ value: Any?) { writer(domain, key, value) }
    /// Writes reach the owning process (Window Manager applies them at once) and later reads see other processes' writes.
    @discardableResult public func synchronize() -> Bool { synchronizer() }

    public static let system = DesktopPreferences(
        read: { CFPreferencesCopyAppValue($1 as CFString, $0 as CFString) },
        write: { CFPreferencesSetAppValue($1 as CFString, $2.map { $0 as CFPropertyList }, $0 as CFString) },
        synchronize: { [finder, windowManager].allSatisfy { CFPreferencesAppSynchronize($0 as CFString) } })

    /// A UI test's synthetic domains, read and written in place. It needs the folder standing in for the Desktop too.
    static func fixture(at path: String, desktopDirectory: String?) -> DesktopPreferences? {
        guard let desktopDirectory, !desktopDirectory.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        func load() -> [String: [String: Any]]? {
            (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: [String: Any]] }
        }
        guard load() != nil else { return nil }
        return DesktopPreferences(
            read: { load()?[$0]?[$1] },
            write: { domain, key, value in
                guard var domains = load() else { return }
                domains[domain, default: [:]][key] = value
                if let data = try? JSONSerialization.data(withJSONObject: domains) { try? data.write(to: url, options: .atomic) }
            },
            synchronize: { load() != nil })
    }

    /// UI acceptance uses its synthetic domains; it never reads or changes Finder or Window Manager. Generic test hosts get
    /// none at all. The attended prototype uses the real system.
    public static func current() -> DesktopPreferences? {
        if let path = TestEnvironment.desktopEnvironment.value() {
            return fixture(at: path, desktopDirectory: TestEnvironment.desktopDirectory.value())
        }
        guard !Settings.isTesting || Bundle.main.bundleIdentifier == "app.porpoise.DesktopPrototype" else { return nil }
        return system
    }

    /// A preference as a flag: missing → `fallback`; anything but 0 or 1 → nil (unrecognized).
    public func flag(_ domain: String, _ key: String, default fallback: Bool) -> Bool? {
        guard let value = read(domain, key) else { return fallback }
        guard let number = value as? NSNumber, number.doubleValue == 0 || number.doubleValue == 1 else { return nil }
        return number.boolValue
    }
}

/// Desktop Mode's preflight: whether Finder's desktop items and widgets are out of Porpoise's way. Porpoise hides them
/// itself (`DesktopSystemSettings`); this reports what is still in the way. Stage Manager and the wallpaper click are the
/// user's to choose: Porpoise's desktop works with either.
public struct DesktopEnvironment: Equatable, Sendable {
    public enum Conflict: String, Sendable {
        case finderItems, finderStageItems, widgets, stageWidgets, unreadable

        public var instruction: String {
            switch self {
            case .finderItems: "Turn off Show items → On Desktop."
            case .finderStageItems: "Turn off Show items → In Stage Manager."
            case .widgets: "Turn off Show widgets → On Desktop."
            case .stageWidgets: "Turn off Show widgets → In Stage Manager."
            case .unreadable: "Desktop settings could not be verified. Keep the macOS desktop until they can be checked."
            }
        }
    }

    public let conflicts: [Conflict]
    public var isReady: Bool { conflicts.isEmpty }
    public static let ready = Self(conflicts: [])

    public init(conflicts: [Conflict]) { self.conflicts = conflicts }

    /// Missing values use the system defaults: Finder items and widgets shown.
    public static func inspect(read: @escaping (_ domain: String, _ key: String) -> Any?) -> Self {
        inspect(DesktopPreferences(read: read, write: { _, _, _ in }))
    }

    public static func inspect(_ preferences: DesktopPreferences) -> Self {
        let wm = DesktopPreferences.windowManager
        var conflicts: [Conflict] = []
        var unreadable = false
        func flag(_ domain: String, _ key: String, default fallback: Bool) -> Bool? {
            let value = preferences.flag(domain, key, default: fallback)
            if value == nil { unreadable = true }
            return value
        }
        let finder = flag(DesktopPreferences.finder, "CreateDesktop", default: true)
        let desktopHidden = flag(wm, "StandardHideDesktopIcons", default: false)
        let stageHidden = flag(wm, "HideDesktop", default: false)
        if finder != false {
            if desktopHidden == false { conflicts.append(.finderItems) }
            if stageHidden == false { conflicts.append(.finderStageItems) }
        }
        if flag(wm, "StandardHideWidgets", default: false) == false { conflicts.append(.widgets) }
        if flag(wm, "StageManagerHideWidgets", default: false) == false { conflicts.append(.stageWidgets) }
        if unreadable { conflicts.append(.unreadable) }
        return Self(conflicts: conflicts)
    }

    public static func current() -> Self {
        guard let preferences = DesktopPreferences.current(), preferences.synchronize() else { return Self(conflicts: [.unreadable]) }
        return inspect(preferences)
    }

    static func fixture(at path: String, desktopDirectory: String?) -> Self {
        DesktopPreferences.fixture(at: path, desktopDirectory: desktopDirectory).map(inspect) ?? Self(conflicts: [.unreadable])
    }

    /// Whether a click on empty desktop space reveals the desktop, as macOS does for a wallpaper click: "Always", or
    /// "Only in Stage Manager" while Stage Manager is on.
    public static func clickRevealsDesktop(_ preferences: DesktopPreferences) -> Bool {
        let wm = DesktopPreferences.windowManager
        return preferences.flag(wm, "EnableStandardClickToShowDesktop", default: true) == true
            || preferences.flag(wm, "GloballyEnabled", default: false) == true
    }

    /// Existing FSEvents infrastructure watches these preferences, including per-host overrides. No idle polling.
    public static func isPreferenceChange(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "Preferences" || name == "ByHost" || name.hasPrefix("com.apple.finder.")
            || name.hasPrefix("com.apple.WindowManager.")
    }
}

/// The macOS settings Desktop Mode changes for the user: Finder's desktop items and widgets are hidden in both desktop
/// modes, so only Porpoise's icons show. Turning Desktop Mode off, or quitting, puts back what the user had. The originals
/// are kept in Porpoise's own defaults until then, so a crash still restores them at the next launch.
public struct DesktopSystemSettings {
    /// The Window Manager keys Desktop Mode sets to true. The two item keys don't matter while Finder's desktop is off.
    public static let hiddenKeys = ["StandardHideDesktopIcons", "HideDesktop", "StandardHideWidgets", "StageManagerHideWidgets"]
    private static let itemKeys: Set<String> = ["StandardHideDesktopIcons", "HideDesktop"]
    public static let savedKey = "desktopModeReplacedSettings"
    /// The process that last applied them: a watcher restores only for the process it watches (`restore(onlyFor:)`).
    public static let ownerKey = "desktopModeReplacedSettingsOwner"

    let preferences: DesktopPreferences
    let store: UserDefaults

    public init(preferences: DesktopPreferences, store: UserDefaults) {
        self.preferences = preferences
        self.store = store
    }

    public static func current() -> Self? {
        DesktopPreferences.current().map { Self(preferences: $0, store: Settings.store) }
    }

    /// What Desktop Mode changed and the value each had before (an empty entry: the key wasn't set).
    public var saved: [String: [String: Any]] { (store.dictionary(forKey: Self.savedKey) as? [String: [String: Any]]) ?? [:] }

    /// Hides what is still shown. An original is recorded before its key is first written and never replaced afterwards.
    /// `owner` (this process) takes over what an earlier session recorded.
    public func apply(owner: Int32 = getpid()) {
        _ = preferences.synchronize()
        let wm = DesktopPreferences.windowManager
        let finderDesktop = preferences.flag(DesktopPreferences.finder, "CreateDesktop", default: true) != false
        var saved = saved, changed = false
        for key in Self.hiddenKeys where finderDesktop || !Self.itemKeys.contains(key) {
            guard preferences.flag(wm, key, default: false) != true else { continue }
            if saved[key] == nil {
                saved[key] = preferences.read(wm, key).map { ["value": $0] } ?? [:]
                store.set(saved, forKey: Self.savedKey)
            }
            preferences.write(wm, key, true)
            changed = true
        }
        if !saved.isEmpty, store.object(forKey: Self.ownerKey) as? Int != Int(owner) { store.set(Int(owner), forKey: Self.ownerKey) }
        if changed { preferences.synchronize() }
    }

    /// Puts back each value Desktop Mode changed, unless the user changed it again since. With `onlyFor`, only if that
    /// process was the last to apply them: a relaunched Porpoise owns them now.
    public func restore(onlyFor owner: Int32? = nil) {
        let saved = saved
        guard !saved.isEmpty else { return }
        if let owner, let recorded = store.object(forKey: Self.ownerKey) as? Int, recorded != Int(owner) { return }
        _ = preferences.synchronize()
        let wm = DesktopPreferences.windowManager
        for (key, entry) in saved where Self.hiddenKeys.contains(key) && preferences.flag(wm, key, default: false) == true {
            preferences.write(wm, key, entry["value"])
        }
        preferences.synchronize()
        store.removeObject(forKey: Self.savedKey)
        store.removeObject(forKey: Self.ownerKey)
    }
}
