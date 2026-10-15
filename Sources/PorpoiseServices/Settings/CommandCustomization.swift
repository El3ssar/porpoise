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
            guard let data = Settings.store.data(forKey: "toolbarCommands"),
                let commands = try? JSONDecoder().decode([ToolbarCommand].self, from: data),
                (try? ToolbarCommand.validate(commands)) != nil
            else { return ToolbarCommand.defaults }
            return commands
        }
        set {
            guard (try? ToolbarCommand.validate(newValue)) != nil, let data = try? JSONEncoder().encode(newValue) else { return }
            Settings.store.set(data, forKey: "toolbarCommands")
            NotificationCenter.default.post(name: Settings.changed, object: "toolbarCommands")
        }
    }
}
