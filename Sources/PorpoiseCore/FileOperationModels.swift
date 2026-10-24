import Foundation

// MARK: - Types

public enum FileOperationKind: String, Sendable {
    case copy, move, link, trash, delete

    public var verb: String {
        switch self {
        case .copy: return "Copying"
        case .move: return "Moving"
        case .link: return "Linking"
        case .trash: return "Moving to Trash"
        case .delete: return "Deleting"
        }
    }
}

/// What to do when the destination already exists (KIO's RenameDialog choices).
public enum ConflictResolution: Sendable, Equatable {
    case skip
    case overwrite
    case overwriteIfOlder
    case overwriteIfDifferent
    case overwriteIfLarger
    case keepBoth
    case rename(String)
    case writeInto  // merge folders
    case cancel
}

/// Folder contents known before asking; bytes is nil when only a listing is available.
public struct TransferFolderSummary: Sendable {
    public let itemCount: Int
    public let bytes: Int64?
    public init(itemCount: Int, bytes: Int64? = nil) { self.itemCount = itemCount; self.bytes = bytes }
}

/// A transfer error carries its own source identity; error and retry arrays need not have the same length.
public struct TransferFailure: Sendable, Equatable {
    public let source: URL?
    public let message: String
    public init(source: URL?, message: String) { self.source = source; self.message = message }
}

public struct ConflictInfo: Sendable {
    public let source: FileItem
    public let sourceFolder: TransferFolderSummary?
    public let destinationFolder: TransferFolderSummary?
    public let destination: FileItem
    public let suggestedName: String
    /// Remaining known name clashes, including this one; nil when a remote listing cannot establish it.
    public let remainingConflicts: Int?
    public let comparisonOptions: TransferCompareOptions
    public let differentItems: Int?
    public let identicalItems: Int?
    public let replacedItems: Int
    public let skippedIdenticalItems: Int
    public init(
        source: FileItem, destination: FileItem, suggestedName: String, remainingConflicts: Int? = nil,
        comparisonOptions: TransferCompareOptions = .init(), replacedItems: Int = 0, skippedIdenticalItems: Int = 0,
        differentItems: Int? = nil, identicalItems: Int? = nil,
        sourceFolder: TransferFolderSummary? = nil, destinationFolder: TransferFolderSummary? = nil
    ) {
        self.source = source
        self.sourceFolder = sourceFolder; self.destinationFolder = destinationFolder
        self.destination = destination
        self.suggestedName = suggestedName
        self.remainingConflicts = remainingConflicts
        self.comparisonOptions = comparisonOptions
        self.differentItems = differentItems
        self.identicalItems = identicalItems
        self.replacedItems = replacedItems
        self.skippedIdenticalItems = skippedIdenticalItems
    }
}

public struct ConflictAnswer: Sendable {
    public var resolution: ConflictResolution
    public var applyToAll: Bool
    public var comparisonMethod: TransferCompareMethod?
    public init(_ resolution: ConflictResolution, applyToAll: Bool = false, comparisonMethod: TransferCompareMethod? = nil) {
        self.resolution = resolution
        self.applyToAll = applyToAll
        self.comparisonMethod = comparisonMethod
    }
}

/// A reversible record of what a job did, used for Undo/Redo.
/// A change made on a cloud service, as Undo sees it. Items keep their URLs (ids), so a rename stores the names.
public struct CloudChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Moved to the service's trash: undone by restoring.
        case trashed
        /// Created, or restored from the trash: undone by moving to the trash.
        case appeared
        case renamed(from: String, to: String)
    }
    public var kind: Kind
    public var urls: [URL]
    /// "Move to Trash", "New Folder", "Rename": what Undo/Redo say, the same both ways.
    public var label: String

    public init(_ kind: Kind, _ urls: [URL], label: String) {
        self.kind = kind
        self.urls = urls
        self.label = label
    }

    /// The record for Redo once this one is undone.
    public var inverse: CloudChange {
        switch kind {
        case .trashed: return CloudChange(.appeared, urls, label: label)
        case .appeared: return CloudChange(.trashed, urls, label: label)
        case .renamed(let from, let to): return CloudChange(.renamed(from: to, to: from), urls, label: label)
        }
    }
}

/// A change made on a server or a device (SFTP, FTP, adb), as Undo sees it. Nothing there has a trash, so only an
/// item still empty is ever removed again.
public struct RemoteChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case renamed(from: URL, to: URL)
        /// A new, empty folder or file: undone by removing it while it is still empty.
        case created(URL, folder: Bool)
        /// An empty folder or file removed by Undo: redone by creating it again.
        case removed(URL, folder: Bool)
    }
    public var kind: Kind
    public var label: String

    public init(_ kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }

    public var urls: [URL] {
        switch kind {
        case .renamed(let from, let to): return [from, to]
        case .created(let url, _), .removed(let url, _): return [url]
        }
    }

    /// The record for Redo once this one is undone.
    public var inverse: RemoteChange {
        switch kind {
        case .renamed(let from, let to): return RemoteChange(.renamed(from: to, to: from), label: label)
        case .created(let url, let folder): return RemoteChange(.removed(url, folder: folder), label: label)
        case .removed(let url, let folder): return RemoteChange(.created(url, folder: folder), label: label)
        }
    }
}

public enum UndoRecord: Sendable {
    case created([URL])  // undo: trash these (copies, links, new folders/files)
    case moved([(from: URL, to: URL)])  // undo: move back
    case trashed([(original: URL, inTrash: URL)])
    case renamed(from: URL, to: URL)
    /// Physical moves in execution order, including temporary staging paths.
    case batchRenamed([RenameMove])
    /// Google Drive and other services: undone through the service, not the file system.
    case cloud(CloudChange)
    /// Servers and devices: undone through their provider.
    case remote(RemoteChange)

    public var label: String {
        switch self {
        case .cloud(let change): return change.label
        case .remote(let change): return change.label
        case .created: return "Create"
        case .moved: return "Move"
        case .trashed: return "Move to Trash"
        case .renamed: return "Rename"
        case .batchRenamed: return "Batch Rename"
        }
    }
}

/// Progress snapshot published by a running job.
public struct JobProgress: Sendable {
    public enum Phase: String, Sendable { case preparing, transferring, verifying }
    public var phase: Phase = .transferring
    public var verifiedBytes: Int64 = 0
    public var retainedCopies: Int = 0
    public var totalFiles: Int = 0
    public var totalFolders: Int = 0
    public var doneFiles: Int = 0
    public var copiedItems: Int = 0
    public var replacedItems: Int = 0
    public var skippedIdenticalItems: Int = 0

    public var kind: FileOperationKind
    public var totalBytes: Int64
    public var doneBytes: Int64
    public var totalItems: Int
    public var doneItems: Int
    public var currentName: String
    public var destination: URL?
    public init(kind: FileOperationKind, totalBytes: Int64, doneBytes: Int64, totalItems: Int, doneItems: Int, currentName: String, destination: URL?)
    {
        self.kind = kind; self.totalBytes = totalBytes; self.doneBytes = doneBytes; self.totalItems = totalItems
        self.doneItems = doneItems; self.currentName = currentName; self.destination = destination
    }
    public var fraction: Double {
        if totalBytes > 0 { return Double(doneBytes) / Double(totalBytes) }
        return totalItems > 0 ? Double(doneItems) / Double(totalItems) : 0
    }
}

public enum FileOperationError: Error, LocalizedError {
    case cancelled
    /// Stopped where it was, its partial copy kept for resuming later (the app quitting).
    case interrupted
    case intoItself(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The operation was cancelled."
        case .interrupted: return "The operation was interrupted."
        case .intoItself(let n): return "The folder “\(n)” cannot be copied or moved into itself."
        case .failed(let m): return m
        }
    }
}

/// Where an interrupted copy of one file stopped: its partial copy and how many bytes of it are good.
public struct ResumePoint: Codable, Equatable, Sendable {
    public var staging: URL
    public var offset: Int64
    public init(staging: URL, offset: Int64) {
        self.staging = staging
        self.offset = offset
    }
}

/// What a job reports about each of its top-level items as it goes (for the journal that lets an interrupted job
/// be resumed after a relaunch). Called on the job's thread.
public enum JobEvent: Codable, Sendable, Equatable {
    /// Started; `staging` is the hidden item the copy is written to before it takes its name.
    case started(index: Int, staging: URL?)
    /// A resumable copy (a large file) has this many good bytes in its staging file.
    case copied(index: Int, point: ResumePoint)
    /// The item is complete at `target`; a move still removes its source after this.
    case placed(index: Int, target: URL)
    case finished(index: Int, outcome: ItemOutcome)
}

public enum ItemOutcome: String, Codable, Sendable {
    case done, skipped, failed, cancelled
}
