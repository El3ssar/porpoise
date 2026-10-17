import Foundation

/// A default or apply-to-all name-clash rule, evaluated independently for each file.
public enum TransferConflictRule: String, Codable, CaseIterable, Sendable {
    case ask, replace, newer, different, larger, keepBoth, skip

    public var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .replace: return "Replace"
        case .newer: return "Replace if newer"
        case .different: return "Replace if different, skip if identical"
        case .larger: return "Replace if larger"
        case .keepBoth: return "Keep Both"
        case .skip: return "Skip"
        }
    }

    public var resolution: ConflictResolution? {
        switch self {
        case .ask: return nil
        case .replace: return .overwrite
        case .newer: return .overwriteIfOlder
        case .different: return .overwriteIfDifferent
        case .larger: return .overwriteIfLarger
        case .keepBoth: return .keepBoth
        case .skip: return .skip
        }
    }
}

/// Metadata and link semantics for copy conflict rules.
public enum TransferComparison {
    public static func entry(_ item: FileItem, hash: String? = nil) -> TransferEntry {
        TransferEntry(
            kind: item.isSymlink ? .symlink : item.isDirectory ? .directory : .file,
            size: item.size, modified: item.modificationDate, hash: hash, linkTarget: item.linkDestination)
    }
}
