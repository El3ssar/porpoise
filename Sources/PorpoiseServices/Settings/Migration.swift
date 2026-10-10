import Foundation

/// One-time import of settings and places from the app's earlier name ("Dolphin", bundle ID org.kde.dolphin-mac).
public enum Migration {
    private static let oldDomain = "org.kde.dolphin-mac" as CFString
    private static let doneKey = "migratedFromDolphin"

    public static func run() {
        guard !Settings.isTesting else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        // Settings: copy every key the old app stored, unless already set here.
        if let keys = CFPreferencesCopyKeyList(oldDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            for key in keys where defaults.object(forKey: key) == nil && !key.hasPrefix("NSWindow Frame") {
                if let value = CFPreferencesCopyAppValue(key as CFString, oldDomain) { defaults.set(value, forKey: key) }
            }
        }
        // Places (places.json).
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("Dolphin/places.json"), new = support.appendingPathComponent("Porpoise/places.json")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: old, to: new)
        }
    }
}
