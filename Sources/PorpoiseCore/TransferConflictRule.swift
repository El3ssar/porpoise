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

extension ConflictResolution {
    /// Size/date comparison is metadata-only. Equal metadata never establishes byte-identical contents.
    /// Missing timestamps cannot justify a conditional replacement by date.
    public func shouldReplace(source: FileItem, destination: FileItem, options: TransferCompareOptions = .init()) -> Bool {
        switch self {
        case .overwrite: return true
        case .overwriteIfOlder:
            guard let sourceDate = source.modificationDate, let destinationDate = destination.modificationDate else { return false }
            return sourceDate.timeIntervalSince(destinationDate) > options.timestampTolerance
        case .overwriteIfDifferent:
            return TransferComparator.statusOf(TransferComparison.entry(source), TransferComparison.entry(destination), options: options) != .same
        case .overwriteIfLarger: return source.size > destination.size
        default: return false
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
