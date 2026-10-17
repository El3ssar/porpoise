import AppKit
import PorpoiseCore
import PorpoiseServices
import Testing

@testable import Porpoise

extension AppearanceLayoutTests {
    @Test(.timeLimit(.minutes(1))) @MainActor func foldersPanelExpandsNetworkNodesLazilyAndFollowsNavigation() async throws {
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
        for _ in 0..<500 where outline.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let folder = try #require(outline.item(atRow: 1) as? RemoteFolderTree.Node)
        #expect(folder.name == "Visible folder" && folder.children == nil)
        #expect(outline.isExpandable(folder))
        #expect(provider.count == 1)
        outline.expandItem(folder)
        for _ in 0..<500 where outline.numberOfRows < 4 { try await Task.sleep(for: .milliseconds(20)) }
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
    @Test(.timeLimit(.minutes(1))) @MainActor func deepRemoteNavigationKeepsServerRootAndUnvisitedSiblings() async throws {
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
        for _ in 0..<500 where outline.numberOfRows < 4 { try await Task.sleep(for: .milliseconds(20)) }
        let originalRoot = try #require(outline.item(atRow: 0) as? RemoteFolderTree.Node)
        #expect(originalRoot.url == root)
        let selected = try #require(outline.item(atRow: outline.selectedRow) as? RemoteFolderTree.Node)
        #expect(RemoteFolderTree.sameLocation(selected.url, target))
        let sibling = try #require(originalRoot.children?.first { $0.name == "Z sibling" })
        #expect(sibling.children == nil && provider.count == 2)
        let otherTarget = sibling.url.appendingPathComponent("nested", isDirectory: true)
        panel.currentURL = otherTarget
        for _ in 0..<500 where outline.numberOfRows < 5 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(outline.item(atRow: 0) as? RemoteFolderTree.Node === originalRoot)
        let nextSelection = try #require(outline.item(atRow: outline.selectedRow) as? RemoteFolderTree.Node)
        #expect(RemoteFolderTree.sameLocation(nextSelection.url, otherTarget))
        #expect(originalRoot.children?.count == 2 && provider.count == 3)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func unknownCloudParentsUseAccountTopWithoutInventingATreeChild() async throws {
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
        for _ in 0..<500 where outline.numberOfRows < 3 { try await Task.sleep(for: .milliseconds(20)) }
        let top = try #require(outline.item(atRow: 0) as? RemoteFolderTree.Node)
        #expect(top.url == root && top.url != target)
        #expect(top.children?.contains { RemoteFolderTree.sameLocation($0.url, target) } == false)
        // A collection stays its own root even when it has no currently available sidebar row.
        let collection = backend.url(account.id, root: .sharedDrives)
        panel.currentURL = collection
        #expect((outline.item(atRow: 0) as? RemoteFolderTree.Node)?.url == collection)
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
