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
    /// What a shared appearance file would have terminals run, when that differs from now: its shell, the shell's
    /// arguments, the external terminal and its command (one line each). Empty when it changes nothing of that.
    public func appearanceCommands(in data: Data) throws -> [String] {
        let value = try JSONDecoder().decode(AppearancePreferences.self, from: data), now = appearancePreferences
        var out: [String] = []
        let shell = value.shell == .custom ? value.customShell : value.shell.rawValue
        if value.shell != now.shell || value.customShell != now.customShell || value.shellArguments != now.shellArguments {
            out.append("Shell: " + ([shell] + value.shellArguments).joined(separator: " "))
        }
        if value.externalTerminal != now.externalTerminal || value.externalCommand != now.externalCommand {
            out.append("Terminal: " + (value.externalTerminal == .custom ? value.externalCommand : value.externalTerminal.rawValue))
        }
        return out
    }

    /// Takes the appearance in a shared file. What terminals run (shell, arguments, external terminal and command) comes
    /// along only with `includingCommands` (after asking: a file from someone else could otherwise run any command the
    /// next time a terminal opens); else those stay as they are.
    public func importAppearance(_ data: Data, includingCommands: Bool = false) throws {
        var value = try JSONDecoder().decode(AppearancePreferences.self, from: data)
        if !includingCommands {
            let current = appearancePreferences
            value.shell = current.shell
            value.customShell = current.customShell
            value.shellArguments = current.shellArguments
            value.externalTerminal = current.externalTerminal
            value.externalCommand = current.externalCommand
        }
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
