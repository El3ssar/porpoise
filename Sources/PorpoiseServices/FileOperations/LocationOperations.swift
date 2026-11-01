import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Why a file action on a location was refused, in the user's words.
public enum LocationOperationError: LocalizedError, Equatable {
    case exists(String)
    case invalidName(String)
    /// Undoing a new item that something has been put in since.
    case notEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .exists(let name): return "An item named “\(name)” is already in this folder."
        case .invalidName(let name): return "“\(name)” is not a valid name."
        case .notEmpty(let name): return "“\(name)” has changed since it was created, so it was left in place."
        }
    }
}

/// File actions on a folder on this Mac, or on a server or device (SFTP, FTP, adb, and the Drive provider where a
/// path is all that's known): the same calls for each, with the name check and the undo record each one needs.
/// Calls block (a server may be slow), so they run off the main thread; cloud folders' own edits go through
/// `CloudAccounts`.
public struct LocationOperations {
    private enum Backend {
        case local
        case remote(RemoteProvider)
    }
    private let backend: Backend

    public init(for url: URL) {
        backend = RemoteFS.provider(for: url).map(Backend.remote) ?? .local
    }

    init(provider: RemoteProvider) { backend = .remote(provider) }

    /// Whether new items can be made in `folder`. On this Mac a root-owned folder can (the action asks to
    /// authenticate, as Finder does) and a read-only volume can't: its mount flags say so even for the sealed system
    /// volume, where `volumeIsReadOnly` doesn't.
    public func canAddItems(_ folder: URL) -> Bool {
        switch backend {
        case .remote: return LocationKind.of(folder) != .archive
        case .local:
            guard folder.isFileURL else { return false }
            if FileManager.default.isWritableFile(atPath: folder.path) { return true }
            var fs = statfs()
            guard statfs(folder.path, &fs) == 0 else { return false }
            return fs.f_flags & UInt32(MNT_RDONLY) == 0
        }
    }

    /// Whether `url` is a folder that can be opened.
    public func folderExists(_ url: URL) -> Bool {
        switch backend {
        case .remote(let provider): return (try? provider.list(url)) != nil
        case .local:
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
    }

    /// Advisory suggested name. Mutation callers must still perform authoritative/exclusive creation.
    /// An unavailable listing does not prove that the returned name is unused.
    public func uniqueName(_ base: String, ext: String = "", in folder: URL) -> String {
        let taken = (try? takenNames(in: folder)) ?? { _ in false }
        let named = { (n: Int) in (n == 1 ? base : "\(base) \(n)") + (ext.isEmpty ? "" : "." + ext) }
        var n = 1
        while taken(named(n)) { n += 1 }
        return named(n)
    }

    /// Renames `url`, refusing a name another item already has. No undo record when the name didn't change.
    public func rename(_ url: URL, to name: String) throws -> (url: URL, undo: UndoRecord?) {
        switch backend {
        case .local:
            let new = try FileActions.rename(url, to: name)
            return (new, new == url ? nil : .renamed(from: url, to: new))
        case .remote(let provider):
            guard name != url.lastPathComponent else { return (url, nil) }
            try check(name, in: url.deletingLastPathComponent(), renaming: url.lastPathComponent)
            try provider.rename(url, to: name)
            let new = url.deletingLastPathComponent().appendingPathComponent(name)
            return (new, .remote(RemoteChange(.renamed(from: url, to: new), label: "Rename")))
        }
    }

    /// Makes the folder `url` (and the folders above it on this Mac), refusing a name already there.
    @discardableResult public func makeFolder(_ url: URL) throws -> UndoRecord {
        switch backend {
        case .local:
            _ = try FileActions.makeFolder(named: url.lastPathComponent, in: url.deletingLastPathComponent())
            return .created([url])
        case .remote(let provider):
            try check(url.lastPathComponent, in: url.deletingLastPathComponent())
            try provider.createFolder(url)
            return .remote(RemoteChange(.created(url, folder: true), label: "New Folder"))
        }
    }

    /// Creates a file without replacing anything that appeared under its name meanwhile.
    @discardableResult public func makeFile(_ url: URL, contents: Data = Data()) throws -> UndoRecord {
        switch backend {
        case .local:
            return .created([try FileActions.makeFile(named: url.lastPathComponent, in: url.deletingLastPathComponent(), contents: contents)])
        case .remote(let provider):
            try check(url.lastPathComponent, in: url.deletingLastPathComponent())
            try provider.createFile(url, contents: contents)
            return .remote(RemoteChange(.created(url, folder: false), label: "New File", initialContents: contents.isEmpty ? nil : contents))
        }
    }

    @discardableResult public func makeEmptyFile(_ url: URL) throws -> UndoRecord { try makeFile(url) }

    /// Undoes (or redoes) a server change. Every created file requires a conditional removal receipt;
    /// a server without that guarantee keeps the file and explains why Undo cannot safely remove it.
    public static func revert(_ change: RemoteChange) throws {
        guard let provider = change.urls.first.flatMap(RemoteFS.provider(for:)) else { throw CocoaError(.featureUnsupported) }
        let operations = LocationOperations(provider: provider)
        switch change.kind {
        case .renamed(let from, let to):
            _ = try operations.rename(to, to: from.lastPathComponent)
        case .created(let url, let folder):
            if folder {
                do { try provider.removeEmptyFolder(url) } catch {
                    if (try? provider.list(url))?.isEmpty == false { throw LocationOperationError.notEmpty(url.lastPathComponent) }
                    throw error
                }
            } else {
                let item = try provider.list(url.deletingLastPathComponent()).first { $0.name == url.lastPathComponent }
                guard let item else { return }  // already gone
                guard let conditional = provider as? RemoteTransferConditionalRemoval else {
                    throw RemoteError.unsupported(
                        "Undo cannot safely remove this file on this connection because the server cannot conditionally remove the version checked. The file has been kept."
                    )
                }
                // The receipt precedes the read: a writer changing even an empty file during verification
                // invalidates removal. Never fall back to an ordinary delete after checking its size.
                let receipt = try conditional.captureTransferRemoval(url)
                let expected = change.initialContents ?? Data()
                guard item.size == Int64(expected.count) else { throw LocationOperationError.notEmpty(url.lastPathComponent) }
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-new-item-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: scratch) }
                let local = try provider.download(url, into: scratch)
                guard try Data(contentsOf: local) == expected else { throw LocationOperationError.notEmpty(url.lastPathComponent) }
                try receipt.removeSource()
            }
        case .removed(let url, let folder):
            if folder { try operations.makeFolder(url) } else { try operations.makeFile(url, contents: change.initialContents ?? Data()) }
        }
    }

    /// Refuses `name` in `folder` when it isn't a single name or another item has it (ignoring case, as many servers
    /// do); `renaming` is the item's own name, which a change of case may reuse.
    private func check(_ name: String, in folder: URL, renaming own: String? = nil) throws {
        guard FileActions.isValidName(name) else { throw LocationOperationError.invalidName(name) }
        let taken = try takenNames(in: folder)
        if taken(name), own?.compare(name, options: .caseInsensitive) != .orderedSame { throw LocationOperationError.exists(name) }
    }

    /// Whether a name is taken in `folder`: on this Mac what the file system says (a case-insensitive volume refuses
    /// "A" beside "a"), on a server what its listing has, ignoring case.
    private func takenNames(in folder: URL) throws -> (String) -> Bool {
        switch backend {
        case .local:
            return { FileJob.itemExists(at: folder.appendingPathComponent($0)) }
        case .remote(let provider):
            let names = Set(try provider.list(folder).map { $0.name.lowercased() })
            return { names.contains($0.lowercased()) }
        }
    }

}
