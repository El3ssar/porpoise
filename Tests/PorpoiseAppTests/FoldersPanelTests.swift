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
        for _ in 0..<500 where outline.numberOfRows < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(outline.numberOfRows == 3 && provider.count == 2)
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
}

private final class FolderPanelProvider: RemoteProvider, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    init(root: URL) { self.root = root }
    func list(_ folder: URL) throws -> [FileItem] {
        lock.withLock { calls += 1 }
        if folder == root { return [FileItem(url: root.appendingPathComponent("opaque"), name: "Visible folder", isDirectory: true)] }
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
