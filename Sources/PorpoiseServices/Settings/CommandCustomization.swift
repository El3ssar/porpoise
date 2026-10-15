import Foundation
import PorpoiseCore

extension Settings {
    public var keyboardShortcuts: ShortcutPreferences {
        get { Settings.store.data(forKey: "keyboardShortcuts").flatMap { try? ShortcutPreferences.decode($0) } ?? ShortcutPreferences() }
        set {
            guard let data = try? newValue.encoded() else { return }
            Settings.store.set(data, forKey: "keyboardShortcuts")
            NotificationCenter.default.post(name: Settings.changed, object: "keyboardShortcuts")
        }
    }
    public func importKeyboardShortcuts(_ data: Data, actions: [ShortcutAction]) throws {
        let preferences = try ShortcutPreferences.decode(data)
        guard preferences.conflicts(actions: actions).isEmpty else {
            throw ShortcutError.invalid("The shortcut file contains conflicting bindings. No bindings were changed.")
        }
        keyboardShortcuts = preferences
    }
    public var toolbarCommands: [ToolbarCommand] {
        get {
            // One by one: an item this version doesn't have (after a downgrade) is left out, not the whole layout.
            guard let data = Settings.store.data(forKey: "toolbarCommands"), let names = try? JSONDecoder().decode([String].self, from: data)
            else { return ToolbarCommand.defaults }
            var commands: [ToolbarCommand] = []
            for c in names.compactMap(ToolbarCommand.init(rawValue:)) where !commands.contains(c) { commands.append(c) }
            if !commands.contains(.location) { commands.insert(.location, at: min(4, commands.count)) }
            return commands
        }
        set {
            guard (try? ToolbarCommand.validate(newValue)) != nil, let data = try? JSONEncoder().encode(newValue) else { return }
            Settings.store.set(data, forKey: "toolbarCommands")
            NotificationCenter.default.post(name: Settings.changed, object: "toolbarCommands")
        }
    }
}
