import Foundation
import PorpoiseCore

// Services that keep nothing between launches.
extension CloudBackend {
    public func savedAt(for folder: URL) -> Date? { nil }
}

/// How fresh a cloud folder is, in the user's words: what the offline message says.
extension CloudAccounts {
    public func savedAt(for folder: URL) -> Date? { backend?.savedAt(for: folder) }

    /// "You’re offline. Showing Google Drive as it was today at 14:02." (`hasListing`: the folder shows a saved listing;
    /// without one it can only open once the connection is back.)
    public func offlineMessage(for folder: URL, hasListing: Bool, now: Date = Date()) -> String {
        let name = account(for: folder).map { title($0.id) } ?? providerTitle(for: folder)
        guard hasListing else { return "You’re offline. This folder opens when you’re back online." }
        guard let saved = savedAt(for: folder) else { return "You’re offline. Showing \(name) as it was when you last opened it." }
        return "You’re offline. Showing \(name) as it was \(Self.when(saved, now: now))."
    }

    /// "today at 14:02", "yesterday at 09:12", "on Monday at 18:40", "on 12 Oct 2026 at 10:15".
    static func when(_ date: Date, now: Date) -> String {
        let text = FileFormat.relativeDate(date, now: now)
        if text.hasPrefix("Today") || text.hasPrefix("Yesterday") { return text.prefix(1).lowercased() + text.dropFirst() }
        return "on " + text
    }
}
