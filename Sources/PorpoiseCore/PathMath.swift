import Foundation

/// Path arithmetic the app needs (moved here from the app target so it's tested).
public enum PathMath {
    /// Deepest folder containing all `urls` (their shared parent in the usual case). `urls` must not be empty.
    public static func commonFolder(of urls: [URL]) -> URL {
        var parts = urls[0].deletingLastPathComponent().standardizedFileURL.pathComponents
        for u in urls.dropFirst() {
            let other = u.deletingLastPathComponent().standardizedFileURL.pathComponents
            parts = Array(zip(parts, other).prefix { $0 == $1 }.map(\.0))
        }
        return URL(fileURLWithPath: NSString.path(withComponents: parts.isEmpty ? ["/"] : parts), isDirectory: true)
    }

}
