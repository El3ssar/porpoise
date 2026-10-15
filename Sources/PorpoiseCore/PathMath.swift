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

    /// The same file however it's spelled: searches report /private/tmp/… for what the folder lists as /tmp/….
    public static func sameFileKey(_ url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }
        // Items' URLs are already standard (made from paths); standardizing thousands of them each change would cost.
        let p = url.path
        return p.hasPrefix("/private/") ? String(p.dropFirst(8)) : p
    }
}
