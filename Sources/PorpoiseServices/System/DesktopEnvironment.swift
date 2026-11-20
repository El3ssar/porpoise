import CoreFoundation
import Foundation

/// A read-only preflight for Porpoise's exclusive desktop. These macOS preference keys are not a public
/// configuration API: unrecognized values fail closed, and Porpoise never writes them or restarts Finder.
public struct DesktopEnvironment: Equatable, Sendable {
    public enum Conflict: String, Sendable {
        case finderItems, finderStageItems, stageManager, widgets, stageWidgets, wallpaperClick, unreadable

        public var instruction: String {
            switch self {
            case .finderItems: "Turn off Show items → On Desktop."
            case .finderStageItems: "Turn off Show items → In Stage Manager."
            case .stageManager: "Turn off Stage Manager."
            case .widgets: "Turn off Show widgets → On Desktop."
            case .stageWidgets: "Turn off Show widgets → In Stage Manager."
            case .wallpaperClick: "Set Click wallpaper to show desktop to Only in Stage Manager."
            case .unreadable: "Desktop settings could not be verified. Keep the macOS desktop until they can be checked."
            }
        }
    }

    public let conflicts: [Conflict]
    public var isReady: Bool { conflicts.isEmpty }
    public static let ready = Self(conflicts: [])

    public init(conflicts: [Conflict]) { self.conflicts = conflicts }

    /// Missing values use the system defaults: Finder items/widgets shown, Stage Manager off and wallpaper click on.
    /// The injected reader lets tests cover configuration changes without reading the user's preferences.
    public static func inspect(read: (_ domain: String, _ key: String) -> Any?) -> Self {
        var unreadable = false
        func flag(_ domain: String, _ key: String, default fallback: Bool) -> Bool? {
            guard let value = read(domain, key) else { return fallback }
            guard let number = value as? NSNumber, number.doubleValue == 0 || number.doubleValue == 1 else {
                unreadable = true
                return nil
            }
            return number.boolValue
        }
        let finder = flag("com.apple.finder", "CreateDesktop", default: true)
        let windowManager = "com.apple.WindowManager"
        var conflicts: [Conflict] = []
        let desktopHidden = flag(windowManager, "StandardHideDesktopIcons", default: false)
        let stageHidden = flag(windowManager, "HideDesktop", default: false)
        if finder != false {
            if desktopHidden == false { conflicts.append(.finderItems) }
            if stageHidden == false { conflicts.append(.finderStageItems) }
        }
        if flag(windowManager, "GloballyEnabled", default: false) == true { conflicts.append(.stageManager) }
        if flag(windowManager, "StandardHideWidgets", default: false) == false { conflicts.append(.widgets) }
        if flag(windowManager, "StageManagerHideWidgets", default: false) == false { conflicts.append(.stageWidgets) }
        if flag(windowManager, "EnableStandardClickToShowDesktop", default: true) == true { conflicts.append(.wallpaperClick) }
        if unreadable { conflicts.append(.unreadable) }
        return Self(conflicts: conflicts)
    }

    public static func current() -> Self {
        // UI acceptance uses a complete synthetic snapshot; it never changes Finder or Window Manager.
        if let path = TestEnvironment.desktopEnvironment.value() {
            return fixture(at: path, desktopDirectory: TestEnvironment.desktopDirectory.value())
        }
        // Generic test hosts must explicitly inject a snapshot. The attended prototype can check the real system.
        guard !Settings.isTesting || Bundle.main.bundleIdentifier == "app.porpoise.DesktopPrototype" else {
            return Self(conflicts: [.unreadable])
        }
        let domains = ["com.apple.finder", "com.apple.WindowManager"]
        guard domains.allSatisfy({ CFPreferencesAppSynchronize($0 as CFString) }) else {
            return Self(conflicts: [.unreadable])
        }
        return inspect { CFPreferencesCopyAppValue($1 as CFString, $0 as CFString) }
    }

    static func fixture(at path: String, desktopDirectory: String?) -> Self {
        guard let desktopDirectory, !desktopDirectory.isEmpty,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let domains = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        else { return Self(conflicts: [.unreadable]) }
        return inspect { domains[$0]?[$1] }
    }

    /// Existing FSEvents infrastructure watches these preferences, including per-host overrides. No idle polling.
    public static func isPreferenceChange(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "Preferences" || name == "ByHost" || name.hasPrefix("com.apple.finder.")
            || name.hasPrefix("com.apple.WindowManager.")
    }
}
