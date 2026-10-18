import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

// Each test has a settings store of its own (`.isolatedSettings`): another test's settings reset (Settings.changed
// with no key) rebuilt the panel's tree mid-test and listed the root again, so the request counts below were off.
// The time limits leave room for the 60 s waits on CI's runner.
extension AppearanceLayoutTests {
    @Test(.isolatedSettings, .timeLimit(.minutes(5))) @MainActor func foldersPanelExpandsNetworkNodesLazilyAndFollowsNavigation() async throws {
        _ = NSApplication.shared
        let previous = Settings.isTesting
        Settings.isTesting = true
        defer { Settings.isTesting = previous }
        let root = URL(string: "sftp://folders-\(UUID().uuidString.lowercased()).invalid/")!
        let provider = FolderPanelProvider(root: root)
        #expect(RemoteFS.installTestingProvider(provider, for: root))
        defer { RemoteFS.registerCloud(nil, for: root) }
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        panel.currentURL = root
        let scroll = try #require(panel.subviews.first as? NSScrollView)
        let outline = try #require(scroll.documentView as? NSOutlineView)
        await expectEventually { outline.numberOfRows >= 2 }
        let folder = try #require(outline.item(atRow: 1) as? RemoteFolderTree.Node)
        #expect(folder.name == "Visible folder" && folder.children == nil)
        #expect(outline.isExpandable(folder))
        #expect(provider.count == 1)
        outline.expandItem(folder)
        await expectEventually { outline.numberOfRows >= 4 }
        #expect(outline.numberOfRows == 4 && provider.count == 2)
        #expect(outline.isItemExpanded(folder))
        let nested = try #require(outline.item(atRow: 2) as? RemoteFolderTree.Node)
        panel.currentURL = nested.url
        #expect(outline.item(atRow: outline.selectedRow) as? RemoteFolderTree.Node === nested)
        outline.collapseItem(folder)
        #expect(!folder.isExpanded)
        outline.expandItem(folder)
        #expect(provider.count == 2)
        // Going back to a local folder discards the remote tree; late callbacks cannot replace it.
        panel.currentURL = FileManager.default.temporaryDirectory
        #expect(!(outline.item(atRow: 0) is RemoteFolderTree.Node))
    }
    @Test(.isolatedSettings, .timeLimit(.minutes(5))) @MainActor func deepRemoteNavigationKeepsServerRootAndUnvisitedSiblings() async throws {
        _ = NSApplication.shared
        let previous = Settings.isTesting
        Settings.isTesting = true
        defer { Settings.isTesting = previous }
        let root = URL(string: "sftp://deep-folders-\(UUID().uuidString.lowercased()).invalid/")!
        let provider = FolderPanelProvider(root: root)
        #expect(RemoteFS.installTestingProvider(provider, for: root))
        defer { RemoteFS.registerCloud(nil, for: root) }
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let target = root.appendingPathComponent("opaque/nested", isDirectory: true)
        panel.currentURL = target
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        await expectEventually { outline.numberOfRows >= 4 }
        let originalRoot = try #require(outline.item(atRow: 0) as? RemoteFolderTree.Node)
        #expect(originalRoot.url == root)
        let selected = try #require(outline.item(atRow: outline.selectedRow) as? RemoteFolderTree.Node)
        #expect(RemoteFolderTree.sameLocation(selected.url, target))
        let sibling = try #require(originalRoot.children?.first { $0.name == "Z sibling" })
        #expect(sibling.children == nil && provider.count == 2)
        let otherTarget = sibling.url.appendingPathComponent("nested", isDirectory: true)
        panel.currentURL = otherTarget
        await expectEventually { outline.numberOfRows >= 5 }
        #expect(outline.item(atRow: 0) as? RemoteFolderTree.Node === originalRoot)
        let nextSelection = try #require(outline.item(atRow: outline.selectedRow) as? RemoteFolderTree.Node)
        #expect(RemoteFolderTree.sameLocation(nextSelection.url, otherTarget))
        #expect(originalRoot.children?.count == 2 && provider.count == 3)
    }

    @Test(.isolatedSettings, .timeLimit(.minutes(5))) @MainActor func unknownCloudParentsUseAccountTopWithoutInventingATreeChild() async throws {
        _ = NSApplication.shared
        let previousTesting = Settings.isTesting, previousBackend = CloudAccounts.shared.backend
        Settings.isTesting = true
        defer { CloudAccounts.shared.backend = previousBackend; Settings.isTesting = previousTesting }
        let id = UUID()
        let account = CloudAccount(id: id.uuidString.lowercased(), email: "tree@example.invalid", displayName: "Tree fixture")
        let backend = DemoCloudBackend(accounts: [account])
        CloudAccounts.shared.backend = backend
        let root = backend.url(account.id, root: .myDrive)
        let target = DriveLocation(accountID: id, collection: .folder("unresolved")).url
        #expect(CloudAccounts.shared.ancestors(of: target).isEmpty)
        #expect(RemoteFS.installTestingProvider(FolderPanelProvider(root: root), for: root))
        defer { RemoteFS.registerCloud(nil, for: root) }
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        panel.currentURL = target
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        await expectEventually { outline.numberOfRows >= 3 }
        let top = try #require(outline.item(atRow: 0) as? RemoteFolderTree.Node)
        #expect(top.url == root && top.url != target)
        #expect(top.children?.contains { RemoteFolderTree.sameLocation($0.url, target) } == false)
        // A collection stays its own root even when it has no currently available sidebar row.
        let collection = backend.url(account.id, root: .sharedDrives)
        panel.currentURL = collection
        #expect((outline.item(atRow: 0) as? RemoteFolderTree.Node)?.url == collection)
    }

    /// The folder with symlinks resolved, as the Folders panel shows it (/private/var, not /var).
    private func realFolder(_ url: URL) -> URL {
        guard let r = realpath(url.path, nil) else { return url }
        defer { free(r) }
        return URL(fileURLWithPath: String(cString: r))
    }

    @Test(.isolatedSettings, .timeLimit(.minutes(5))) @MainActor func foldersPanelListsLocalFoldersOffTheMainThread() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch(), home = realFolder(scratch.url)
        let fm = FileManager.default
        let target = home.appendingPathComponent("a/b/c", isDirectory: true)
        let files = home.appendingPathComponent("files", isDirectory: true)
        let hidden = home.appendingPathComponent(".hidden/inside", isDirectory: true)
        for dir in [target, files, hidden, home.appendingPathComponent("a/sibling")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for i in 0..<3000 { fm.createFile(atPath: files.appendingPathComponent("file-\(i).txt").path, contents: nil) }
        // A package is a file here: a folder holding only one has no disclosure triangle.
        try fm.createDirectory(at: files.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        Settings.shared.homeURL = home
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        func url(_ row: Int) -> URL? { (outline.item(atRow: row) as? FoldersPanel.Node)?.url }

        // The view's folder: the tree is listed level by level on the worker queue and follows it down.
        panel.currentURL = target
        await expectEventually { url(outline.selectedRow)?.path == target.path }
        let rows = (0..<outline.numberOfRows).compactMap { url($0)?.lastPathComponent }
        #expect(rows == ["a", "b", "c", "sibling", "files"])

        // A folder of files: the outline's callbacks answer at once (no listing in them), the triangle from a few entries.
        let node = try #require(
            (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? FoldersPanel.Node }.first { $0.url.path == files.path })
        #expect(!outline.isExpandable(node))
        let cold = FoldersPanel.Node(files)
        #expect(panel.outlineView(outline, numberOfChildrenOfItem: cold) == 0)
        #expect(cold.isLoading)
        await expectEventually { cold.children != nil }
        #expect(cold.children?.isEmpty == true)

        // Expanding a folder not listed yet: it opens at once and its children come when listed.
        let sibling = try #require(
            (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? FoldersPanel.Node }.first {
                $0.url.lastPathComponent == "sibling"
            })
        try fm.createDirectory(at: sibling.url.appendingPathComponent("deep"), withIntermediateDirectories: true)
        sibling.invalidate()
        outline.reloadItem(sibling, reloadChildren: true)
        outline.expandItem(sibling)
        await expectEventually { outline.row(forItem: sibling.children?.first) == outline.row(forItem: sibling) + 1 }
        #expect(outline.isItemExpanded(sibling) && sibling.children?.map(\.url.lastPathComponent) == ["deep"])

        // A folder made after its parent was listed: the parent is listed again, once, and the tree reaches it.
        let later = home.appendingPathComponent("a/later", isDirectory: true)
        try fm.createDirectory(at: later, withIntermediateDirectories: true)
        panel.currentURL = later
        await expectEventually { url(outline.selectedRow)?.path == later.path }
        // A hidden folder on the way to the view's folder is shown anyway.
        panel.currentURL = hidden
        await expectEventually { url(outline.selectedRow)?.path == hidden.path }
        #expect(url(outline.row(forItem: outline.parent(forItem: outline.item(atRow: outline.selectedRow))))?.lastPathComponent == ".hidden")
    }

}

private final class FolderPanelProvider: RemoteProvider, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    init(root: URL) { self.root = root }
    func list(_ folder: URL) throws -> [FileItem] {
        lock.withLock { calls += 1 }
        if folder == root {
            return [
                FileItem(url: root.appendingPathComponent("opaque"), name: "Visible folder", isDirectory: true),
                FileItem(url: root.appendingPathComponent("sibling"), name: "Z sibling", isDirectory: true),
            ]
        }
        return [FileItem(url: folder.appendingPathComponent("nested"), name: "Nested folder", isDirectory: true)]
    }
    func rootTitle(_ url: URL) -> String { "Network fixture" }
    func download(_ remote: URL, into localFolder: URL) throws -> URL { fatalError() }
    func upload(_ local: URL, into remoteFolder: URL) throws { fatalError() }
    func delete(_ remote: [URL]) throws { fatalError() }
    func makeFolder(_ remote: URL) throws { fatalError() }
    func rename(_ remote: URL, to newName: String) throws { fatalError() }
    func move(_ remote: [URL], into folder: URL) throws { fatalError() }
    func copy(_ remote: [URL], into folder: URL) throws { fatalError() }
}
