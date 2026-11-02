import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Renaming and making items behave the same on a server as on this Mac: a name already there is refused (a server
/// rename or upload used to replace it), and Undo takes the change back.
@MainActor @Suite(.serialized, .isolatedSettings) struct LocationOperationsTests {
    /// A server held in memory at sftp://ops-<id>.invalid/.
    func server() -> (MemoryServer, URL) {
        let root = URL(string: "sftp://ops-\(UUID().uuidString.prefix(8).lowercased()).invalid/")!
        let server = MemoryServer(root: root)
        RemoteFS.use(server, for: root)
        return (server, root)
    }

    @Test func aServerRenameRefusesATakenNameAndUndoes() throws {
        let (server, root) = server()
        defer { RemoteFS.use(nil, for: root) }
        server.add("a.txt", size: 3); server.add("B.txt", size: 1)
        let a = root.appendingPathComponent("a.txt")
        let ops = LocationOperations(for: a)
        #expect(throws: LocationOperationError.exists("b.txt")) { try ops.rename(a, to: "b.txt") }  // ignoring case
        #expect(throws: LocationOperationError.invalidName("x/y")) { try ops.rename(a, to: "x/y") }
        #expect(try ops.rename(a, to: "a.txt").undo == nil)
        let renamed = try ops.rename(a, to: "A.txt")  // its own name in another case
        #expect(renamed.url.lastPathComponent == "A.txt" && server.names == ["A.txt", "B.txt"])
        guard case .remote(let change)? = renamed.undo else { Issue.record("no undo"); return }
        #expect(change.label == "Rename" && change.urls == [a, renamed.url])
        try LocationOperations.revert(change)
        #expect(server.names == ["B.txt", "a.txt"])
        try LocationOperations.revert(change.inverse)
        #expect(server.names == ["A.txt", "B.txt"])
    }

    @Test func newServerItemsRefuseTakenNamesAndUndoOnlyWhileEmpty() throws {
        let (server, root) = server()
        defer { RemoteFS.use(nil, for: root) }
        server.add("Notes.txt", size: 10)
        let ops = LocationOperations(for: root)
        // An empty upload over an existing file would have replaced it.
        #expect(throws: LocationOperationError.exists("notes.txt")) { try ops.makeEmptyFile(root.appendingPathComponent("notes.txt")) }
        #expect(server.size("Notes.txt") == 10)
        let folder = root.appendingPathComponent("New Folder")
        guard case .remote(let made) = try ops.makeFolder(folder) else { Issue.record("no undo"); return }
        #expect(throws: LocationOperationError.exists("New Folder")) { try ops.makeFolder(folder) }
        #expect(made.label == "New Folder" && made.inverse.inverse == made)
        server.add("New Folder/inside", size: 0)
        #expect(throws: LocationOperationError.notEmpty("New Folder")) { try LocationOperations.revert(made) }
        server.remove("New Folder/inside")
        try LocationOperations.revert(made)
        #expect(!server.names.contains("New Folder"))
        try LocationOperations.revert(made.inverse)  // Redo
        #expect(server.names.contains("New Folder"))

        let file = root.appendingPathComponent("Empty.txt")
        guard case .remote(let empty) = try ops.makeEmptyFile(file) else { Issue.record("no undo"); return }
        #expect(server.size("Empty.txt") == 0 && empty.label == "New File")
        server.add("Empty.txt", size: 5)  // written since
        #expect(throws: LocationOperationError.notEmpty("Empty.txt")) { try LocationOperations.revert(empty) }
        server.add("Empty.txt", size: 0)
        try LocationOperations.revert(empty)
        #expect(!server.names.contains("Empty.txt"))
        try LocationOperations.revert(empty)  // already gone: nothing to do
        try LocationOperations.revert(empty.inverse)
        #expect(server.size("Empty.txt") == 0)
        #expect(ops.uniqueName("New Folder", in: root) == "New Folder 2" && ops.uniqueName("Report", ext: "zip", in: root) == "Report.zip")
        #expect(ops.canAddItems(root) && ops.folderExists(folder) && !ops.folderExists(root.appendingPathComponent("missing")))
    }

    @Test func undoAndRedoGoThroughTheServer() async throws {
        let (server, root) = server()
        defer { RemoteFS.use(nil, for: root) }
        server.add("old.txt", size: 1)
        let controller = FileOperationsController()
        let renamed = try LocationOperations(for: root).rename(root.appendingPathComponent("old.txt"), to: "new.txt")
        controller.pushUndo(try #require(renamed.undo))
        #expect(controller.undoTitle == "Undo: Rename")
        controller.undo(window: nil)
        try #require(await eventually { controller.canRedo })
        #expect(server.names == ["old.txt"] && !controller.canUndo)
        controller.redo(window: nil)
        try #require(await eventually { controller.canUndo })
        #expect(server.names == ["new.txt"])
        // A refusal puts the record back for another try.
        server.add("old.txt", size: 2)
        controller.undo(window: nil)
        try #require(await eventually { controller.canUndo })
        #expect(server.names == ["new.txt", "old.txt"] && !controller.canRedo)
        #expect(FileOperationsController.urls(of: try #require(renamed.undo)).count == 2)
        #expect(throws: CocoaError.self) { try FileActions.undo(try #require(renamed.undo)) }
    }

    @Test func failedAuthoritativeListingNeverAttemptsCreationOrUpload() throws {
        let (server, root) = server()
        defer { RemoteFS.use(nil, for: root) }
        server.add("existing.txt", size: 17)
        server.failLists = true
        #expect(throws: (any Error).self) { try LocationOperations(for: root).makeEmptyFile(root.appendingPathComponent("existing.txt")) }
        #expect(server.creates == 0 && server.uploads == 0 && server.size("existing.txt") == 17)
    }

    @Test func anotherWriterWinningAfterListingIsPreservedByExclusiveCreation() throws {
        let (server, root) = server()
        defer { RemoteFS.use(nil, for: root) }
        server.beforeCreate = { server.add("raced.txt", size: 23) }
        defer { server.beforeCreate = nil }
        #expect(throws: LocationOperationError.exists("raced.txt")) {
            try LocationOperations(for: root).makeEmptyFile(root.appendingPathComponent("raced.txt"))
        }
        #expect(server.size("raced.txt") == 23 && server.uploads == 0)
    }

    @Test func generatedFilePreservesItsBytesAcrossUndoAndRedo() throws {
        let (server, root) = server()
        defer { RemoteFS.use(nil, for: root) }
        let template = Data("<!DOCTYPE html>\n<html></html>\n".utf8)
        let target = root.appendingPathComponent("page.html")
        guard case .remote(let change) = try LocationOperations(for: root).makeFile(target, contents: template) else {
            Issue.record("missing undo"); return
        }
        #expect(server.data("page.html") == template && change.inverse.inverse == change)
        try LocationOperations.revert(change)
        #expect(server.data("page.html") == nil)
        try LocationOperations.revert(change.inverse)
        #expect(server.data("page.html") == template)
        server.add("page.html", size: 50)
        #expect(throws: LocationOperationError.notEmpty("page.html")) { try LocationOperations.revert(change) }
        #expect(server.size("page.html") == 50)
    }

    @Test func emptyFileChangedAfterVerificationIsNotDeletedByUndo() throws {
        let (server, root) = server()
        defer { RemoteFS.use(nil, for: root); server.afterDownload = nil }
        let target = root.appendingPathComponent("empty.txt")
        guard case .remote(let change) = try LocationOperations(for: root).makeEmptyFile(target) else {
            Issue.record("missing undo"); return
        }
        // Download returns the verified empty revision, then another writer commits real bytes before removal.
        server.afterDownload = { server.add("empty.txt", size: 41) }
        #expect(throws: (any Error).self) { try LocationOperations.revert(change) }
        #expect(server.size("empty.txt") == 41 && server.deletes == 0)
    }

    @Test func emptyFileUndoRefusesAProviderWithoutConditionalRemoval() throws {
        let root = URL(string: "sftp://unversioned-\(UUID().uuidString).invalid/")!
        let server = MemoryServer(root: root)
        let unversioned = UnversionedCreationServer(base: server)
        RemoteFS.use(unversioned, for: root)
        defer { RemoteFS.use(nil, for: root) }
        let target = root.appendingPathComponent("empty.txt")
        guard case .remote(let change) = try LocationOperations(for: root).makeEmptyFile(target) else {
            Issue.record("missing undo"); return
        }
        #expect { try LocationOperations.revert(change) } throws: {
            $0.localizedDescription.contains("Undo cannot safely remove this file")
        }
        #expect(server.size("empty.txt") == 0 && server.deletes == 0)
    }

    @Test func existingLocalFolderNeverProducesCreationUndo() throws {
        let scratch = try Scratch()
        let folder = try scratch.folder("existing")
        try scratch.file("existing/other-writer.txt", "keep")
        #expect(throws: (any Error).self) { try LocationOperations(for: scratch.url).makeFolder(folder) }
        #expect(scratch.read("existing/other-writer.txt") == "keep")
    }

    @Test func thisMacKeepsItsRulesAndNamesCopiesLikeBefore() throws {
        let s = try Scratch()
        try s.file("Archive.zip"); try s.file("Archive 2.zip"); try s.folder("Shots")
        let ops = LocationOperations(for: s.url)
        #expect(ops.uniqueName("Archive", ext: "zip", in: s.url) == "Archive 3.zip")
        #expect(ops.uniqueName("Shots", in: s.url) == "Shots 2")
        let deep = s.path("a/b")
        guard case .created(let made) = try ops.makeFolder(deep) else { Issue.record("no undo"); return }
        #expect(made == [deep] && ops.folderExists(deep) && ops.canAddItems(s.url))
        let renamed = try ops.rename(s.path("Shots"), to: "Pictures")
        guard case .renamed(let from, let to)? = renamed.undo else { Issue.record("no undo"); return }
        #expect(from.path == s.path("Shots").path && to.path == s.path("Pictures").path)
        #expect(throws: (any Error).self) { try ops.rename(s.path("Pictures"), to: "Archive.zip") }
        #expect(!ops.canAddItems(URL(string: "recent:/files")!) && !ops.canAddItems(URL(fileURLWithPath: "/System")))
    }
}

/// A server whose files live in a dictionary: path below the root → (folder, size).
final class MemoryServer: RemoteProvider, RemoteTransferConditionalRemoval, @unchecked Sendable {
    let root: URL
    private var entries: [String: (folder: Bool, size: Int64)] = [:]
    private var listings = 0
    private var bytes: [String: Data] = [:]
    private var revisions: [String: UUID] = [:]
    var failLists = false
    var beforeCreate: (() -> Void)?
    var afterDownload: (() -> Void)?
    private(set) var deletes = 0
    private(set) var creates = 0
    private(set) var uploads = 0
    private let lock = NSLock()
    /// How many times a folder was listed.
    var lists: Int { lock.withLock { listings } }
    init(root: URL) { self.root = root }

    func add(_ path: String, size: Int64, folder: Bool = false) {
        lock.withLock {
            entries[path] = (folder, size)
            bytes[path] = folder ? nil : Data(count: Int(size))
            revisions[path] = UUID()
        }
    }
    func data(_ path: String) -> Data? { lock.withLock { bytes[path] } }
    func remove(_ path: String) {
        lock.withLock {
            entries[path] = nil; bytes[path] = nil; revisions[path] = nil
        }
    }
    func size(_ path: String) -> Int64? { lock.withLock { entries[path]?.size } }
    /// The names at the top, sorted.
    var names: [String] { lock.withLock { entries.keys.filter { !$0.contains("/") }.sorted() } }

    private func key(_ url: URL) -> String { String(url.path.dropFirst()) }
    private func children(of folder: String) -> [String] {
        entries.keys.filter { (($0 as NSString).deletingLastPathComponent) == folder }
    }

    func list(_ folder: URL) throws -> [FileItem] {
        try lock.withLock {
            listings += 1
            if failLists { throw CocoaError(.fileReadNoPermission) }
            let k = key(folder)
            guard k.isEmpty || entries[k]?.folder == true else { throw CocoaError(.fileNoSuchFile) }
            return children(of: k).map {
                let name = ($0 as NSString).lastPathComponent
                return FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: entries[$0]!.folder, size: entries[$0]!.size)
            }
        }
    }
    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        guard let data = data(key(remote)) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let local = localFolder.appendingPathComponent(remote.lastPathComponent)
        try data.write(to: local, options: .withoutOverwriting)
        afterDownload?()
        return local
    }
    func upload(_ local: URL, into remoteFolder: URL) throws {
        let data = try Data(contentsOf: local)
        lock.withLock {
            uploads += 1
            let path = key(remoteFolder.appendingPathComponent(local.lastPathComponent))
            entries[path] = (false, Int64(data.count)); bytes[path] = data; revisions[path] = UUID()
        }
    }
    func createFile(_ remote: URL, contents: Data) throws {
        beforeCreate?()
        try lock.withLock {
            creates += 1
            let path = key(remote)
            guard entries[path] == nil else { throw LocationOperationError.exists(remote.lastPathComponent) }
            entries[path] = (false, Int64(contents.count)); bytes[path] = contents; revisions[path] = UUID()
        }
    }
    func createFolder(_ remote: URL) throws {
        try lock.withLock {
            let path = key(remote)
            guard entries[path] == nil else { throw LocationOperationError.exists(remote.lastPathComponent) }
            entries[path] = (true, 0); revisions[path] = UUID()
        }
    }
    func captureTransferRemoval(_ source: URL) throws -> RemoteRemovalReceipt {
        let path = key(source)
        let revision = try lock.withLock { try #require(revisions[path]) }
        return RemoteRemovalReceipt {
            try self.lock.withLock {
                guard self.revisions[path] == revision else { throw CocoaError(.fileWriteFileExists) }
                self.entries[path] = nil; self.bytes[path] = nil; self.revisions[path] = nil
            }
        }
    }
    func delete(_ remote: [URL]) throws {
        lock.withLock { deletes += 1 }
        for url in remote { remove(key(url)) }
    }
    func makeFolder(_ remote: URL) throws { add(key(remote), size: 0, folder: true) }
    func removeEmptyFolder(_ remote: URL) throws {
        try lock.withLock {
            guard children(of: key(remote)).isEmpty else { throw CocoaError(.fileWriteNoPermission) }
            entries[key(remote)] = nil
        }
    }
    func rename(_ remote: URL, to newName: String) throws {
        try lock.withLock {
            guard let entry = entries[key(remote)] else { throw CocoaError(.fileNoSuchFile) }
            let old = key(remote), new = key(remote.deletingLastPathComponent().appendingPathComponent(newName))
            entries[old] = nil; entries[new] = entry
            bytes[new] = bytes.removeValue(forKey: old)
            revisions[new] = revisions.removeValue(forKey: old)
        }
    }
    func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func rootTitle(_ url: URL) -> String { "Memory" }
}

/// An adapter with safe creation but no conditional-removal guarantee. In particular, default delete
/// must never become the fallback for Undo after a size check.
private final class UnversionedCreationServer: RemoteProvider {
    let base: MemoryServer
    init(base: MemoryServer) { self.base = base }
    func list(_ folder: URL) throws -> [FileItem] { try base.list(folder) }
    func download(_ remote: URL, into localFolder: URL) throws -> URL { try base.download(remote, into: localFolder) }
    func upload(_ local: URL, into remoteFolder: URL) throws { try base.upload(local, into: remoteFolder) }
    func createFile(_ remote: URL, contents: Data) throws { try base.createFile(remote, contents: contents) }
    func delete(_ remote: [URL]) throws { try base.delete(remote) }
    func makeFolder(_ remote: URL) throws { try base.makeFolder(remote) }
    func rename(_ remote: URL, to name: String) throws { try base.rename(remote, to: name) }
    func move(_ remote: [URL], into folder: URL) throws { try base.move(remote, into: folder) }
    func copy(_ remote: [URL], into folder: URL) throws { try base.copy(remote, into: folder) }
    func rootTitle(_ url: URL) -> String { base.rootTitle(url) }
}
