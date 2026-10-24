import Foundation

/// The existing Settings.changed payload: one raw persisted key, or nil for every setting.
public enum SettingsChange: Equatable, Sendable {
    case key(String)
    case all

    /// Unknown key strings are valid. Other names or non-string objects are not decoded; consumers retain their
    /// own existing fallback (some ignore malformed objects, while others refresh everything).
    public init?(_ notification: Notification) {
        guard notification.name == Settings.changed else { return nil }
        if notification.object == nil {
            self = .all
        } else if let key = notification.object as? String {
            self = .key(key)
        } else {
            return nil
        }
    }

    /// Delivers synchronously on the posting thread, with the same notification name and raw object as before.
    public func post(to center: NotificationCenter = .default) {
        let object: String?
        switch self {
        case .key(let key): object = key
        case .all: object = nil
        }
        center.post(name: Settings.changed, object: object)
    }
}
