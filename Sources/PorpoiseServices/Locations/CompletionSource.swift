import Foundation

/// Folder names for path completion. The listing of the folder being typed in is kept, so each keystroke
/// only filters names (and checks whether the matches are folders, once each).
public struct CompletionSource {
    private var dir = ""
    private var names: [String] = []
    private var isFolder: [String: Bool] = [:]

    public init() {}

    public mutating func folders(in dir: String, matching partial: String) -> [String] {
        if dir != self.dir {
            self.dir = dir
            names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            isFolder = [:]
        }
        let lower = partial.lowercased()
        let showDotFiles = partial.hasPrefix(".")
        let candidates = names.filter { $0.lowercased().hasPrefix(lower) && (showDotFiles || !$0.hasPrefix(".")) }
        return candidates.filter { n in
            if let f = isFolder[n] { return f }
            var d: ObjCBool = false
            let f = FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(n), isDirectory: &d) && d.boolValue
            isFolder[n] = f
            return f
        }.sorted()
    }
}
