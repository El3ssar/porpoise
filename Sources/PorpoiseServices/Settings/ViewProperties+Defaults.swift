import Foundation
import PorpoiseCore

extension ViewProperties {
    /// Defaults for special folders belonging to the current user.
    public static func defaults(for url: URL) -> ViewProperties {
        defaults(for: url, home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
