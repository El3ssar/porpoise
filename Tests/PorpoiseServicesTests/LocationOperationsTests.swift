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
final class MemoryServer: RemoteProvider, @unchecked Sendable {
    let root: URL
    private var entries: [String: (folder: Bool, size: Int64)] = [:]
    private var listings = 0
    private let lock = NSLock()
    /// How many times a folder was listed.
    var lists: Int { lock.withLock { listings } }
    init(root: URL) { self.root = root }

    func add(_ path: String, size: Int64, folder: Bool = false) { lock.withLock { entries[path] = (folder, size) } }
    func remove(_ path: String) { lock.withLock { entries[path] = nil } }
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
            let k = key(folder)
            guard k.isEmpty || entries[k]?.folder == true else { throw CocoaError(.fileNoSuchFile) }
            return children(of: k).map {
                let name = ($0 as NSString).lastPathComponent
                return FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: entries[$0]!.folder, size: entries[$0]!.size)
            }
        }
    }
    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        guard let size = size(key(remote)) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let local = localFolder.appendingPathComponent(remote.lastPathComponent)
        try Data(count: Int(size)).write(to: local)
        return local
    }
    func upload(_ local: URL, into remoteFolder: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
        add(key(remoteFolder.appendingPathComponent(local.lastPathComponent)), size: size)
    }
    func delete(_ remote: [URL]) throws { for url in remote { remove(key(url)) } }
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
            entries[key(remote)] = nil
            entries[key(remote.deletingLastPathComponent().appendingPathComponent(newName))] = entry
        }
    }
    func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func rootTitle(_ url: URL) -> String { "Memory" }
}
