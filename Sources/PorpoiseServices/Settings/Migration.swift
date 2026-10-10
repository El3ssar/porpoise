import Foundation

/// One-time import of settings and places from the app's earlier name ("Dolphin", bundle ID org.kde.dolphin-mac).
public enum Migration {
    private static let oldDomain = "org.kde.dolphin-mac"
    private static let doneKey = "migratedFromDolphin"

    public static func run() {
        guard !Settings.isTesting else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        run(from: oldDomain, into: .standard, oldPlaces: support.appendingPathComponent("Dolphin/places.json"),
            newPlaces: support.appendingPathComponent("Porpoise/places.json"))
    }

    /// The import itself, between the given domains and files (tests use throwaway ones).
    static func run(from oldDomain: String, into defaults: UserDefaults, oldPlaces old: URL, newPlaces new: URL) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        // Settings: copy every key the old app stored, unless already set here.
        let domain = oldDomain as CFString
        if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            for key in keys where defaults.object(forKey: key) == nil && !key.hasPrefix("NSWindow Frame") {
                if let value = CFPreferencesCopyAppValue(key as CFString, domain) { defaults.set(value, forKey: key) }
            }
        }
        // Places (places.json).
        let fm = FileManager.default
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: old, to: new)
        }
    }
}
