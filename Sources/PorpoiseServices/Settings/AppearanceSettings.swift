import Foundation
import PorpoiseCore

extension Settings {
    public var appearancePreferences: AppearancePreferences {
        get {
            appearanceLock.lock(); defer { appearanceLock.unlock() }
            guard let data = Settings.store.data(forKey: "appearancePreferences") else {
                var value = AppearancePreferences()
                if let legacy = Settings.store.string(forKey: "terminalApp"),
                    let choice = ExternalTerminalChoice.allCases.first(where: { $0.bundleID == legacy })
                {
                    value.externalTerminal = choice
                }
                return value
            }
            if let cache = appearanceCache, cache.data == data { return cache.value }
            guard let value = try? JSONDecoder().decode(AppearancePreferences.self, from: data),
                (try? value.validate()) != nil
            else { return AppearancePreferences() }
            appearanceCache = (data, value)
            return value
        }
        set {
            guard (try? newValue.validate()) != nil, let data = try? JSONEncoder().encode(newValue) else { return }
            appearanceLock.lock()
            appearanceCache = (data, newValue)
            Settings.store.set(data, forKey: "appearancePreferences")
            appearanceLock.unlock()
            NotificationCenter.default.post(name: Settings.changed, object: "appearancePreferences")
        }
    }
    public func updateAppearance(_ change: (inout AppearancePreferences) -> Void) {
        var value = appearancePreferences; change(&value); appearancePreferences = value
    }
    public func exportAppearance() throws -> Data {
        var value = appearancePreferences
        value.appearance = appearance.rawValue
        value.fileFontName = labelFontName; value.fileFontSize = labelFontSize
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    /// Takes everything about looks from a shared file, but not what it would run: the terminal's shell, its
    /// arguments and the external terminal command stay as they are (a file from someone else could otherwise run
    /// any command the next time a terminal opens).
    public func importAppearance(_ data: Data) throws {
        var value = try JSONDecoder().decode(AppearancePreferences.self, from: data)
        let current = appearancePreferences
        value.shell = current.shell
        value.customShell = current.customShell
        value.shellArguments = current.shellArguments
        value.externalTerminal = current.externalTerminal
        value.externalCommand = current.externalCommand
        try value.validate()
        appearancePreferences = value
        appearance = AppearanceChoice(rawValue: value.appearance) ?? .system
        labelFontName = value.fileFontName; labelFontSize = value.fileFontSize
    }
}

extension Settings {
    public func applyAppearanceIconSizes() {
        let p = appearancePreferences
        var properties = globalViewProperties
        properties.setIconSize(CGFloat(p.iconsSize), for: .icons)
        properties.setIconSize(CGFloat(p.compactSize), for: .compact)
        properties.setIconSize(CGFloat(p.detailsSize), for: .details)
        globalViewProperties = properties
        NotificationCenter.default.post(name: Settings.changed, object: "appearanceIconSizes")
    }
}
