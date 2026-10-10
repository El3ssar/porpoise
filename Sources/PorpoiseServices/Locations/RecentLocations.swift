import Foundation

/// Remembers visited folders for "Recent Locations".
public final class RecentLocations {
    public static let shared = RecentLocations()
    public private(set) var urls: [URL] = []
    private init() {
        urls = (Settings.store.stringArray(forKey: "recentLocations") ?? []).map { URL(fileURLWithPath: $0) }
    }
    public func visit(_ u: URL) {
        guard u.isFileURL else { return }
        urls.removeAll { $0 == u }
        urls.insert(u, at: 0)
        if urls.count > 40 { urls.removeLast(urls.count - 40) }
        Settings.store.set(urls.map(\.path), forKey: "recentLocations")
    }
}
