import Foundation

/// An engine-independent action for an existing destination. Content comparison is deferred to the engine.
public enum ConflictDecision: Equatable, Sendable {
    case cancel, merge, replace, compareContents
    case skip(identical: Bool)
    case rename(String)
}

/// Name-clash semantics shared by local, path-based remote, and opaque-ID cloud transfers.
/// This policy performs no filesystem or provider calls.
public struct ConflictPolicy: Sendable {
    public let source: FileItem
    public let destination: FileItem
    private let mergePackages: Bool

    /// Local packages are atomic for explicit Replace/Write Into, as in the local conflict dialog.
    public init(source: FileItem, destination: FileItem, mergePackages: Bool = true) {
        self.source = source; self.destination = destination; self.mergePackages = mergePackages
    }

    private var physicalFolderPair: Bool {
        source.isDirectory && !source.isSymlink && destination.isDirectory && !destination.isSymlink
    }

    public var isFolderPair: Bool {
        physicalFolderPair && (mergePackages || (!source.isPackage && !destination.isPackage))
    }

    /// Write Into applies only to folders. A sticky custom rename means a fresh suggested name for each clash.
    public func automaticResolution(sticky: ConflictResolution?, rule: TransferConflictRule) -> ConflictResolution? {
        guard let choice = sticky ?? rule.resolution else { return nil }
        if choice == .writeInto && !isFolderPair { return nil }
        if case .rename = choice { return .keepBoth }
        return choice
    }

    public func decision(
        for resolution: ConflictResolution, suggestedName: () -> String, options: TransferCompareOptions = .init()
    ) -> ConflictDecision {
        switch resolution {
        case .cancel: return .cancel
        case .skip: return .skip(identical: false)
        case .keepBoth: return .rename(suggestedName())
        case .rename(let name): return .rename(name)
        case .writeInto: return isFolderPair ? .merge : .skip(identical: false)
        case .overwrite: return isFolderPair ? .merge : .replace
        case .overwriteIfDifferent:
            return physicalFolderPair ? .merge : .compareContents
        case .overwriteIfOlder:
            if physicalFolderPair { return .merge }
            guard let sourceDate = source.modificationDate, let destinationDate = destination.modificationDate else { return .skip(identical: false) }
            return sourceDate.timeIntervalSince(destinationDate) > options.timestampTolerance ? .replace : .skip(identical: false)
        case .overwriteIfLarger:
            if physicalFolderPair { return .merge }
            return source.size > destination.size ? .replace : .skip(identical: false)
        }
    }
}
