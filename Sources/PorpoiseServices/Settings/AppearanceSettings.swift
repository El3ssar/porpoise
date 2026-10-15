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
    public func importAppearance(_ data: Data) throws {
        let value = try JSONDecoder().decode(AppearancePreferences.self, from: data); try value.validate()
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
