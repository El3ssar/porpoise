import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

private final class EmptyLocationProvider: RemoteProvider {
    func list(_ folder: URL) throws -> [FileItem] { [] }
    func download(_ remote: URL, into localFolder: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
    func upload(_ local: URL, into remoteFolder: URL) throws {}
    func delete(_ remote: [URL]) throws {}
    func makeFolder(_ remote: URL) throws {}
    func rename(_ remote: URL, to newName: String) throws {}
    func move(_ remote: [URL], into folder: URL) throws {}
    func copy(_ remote: [URL], into folder: URL) throws {}
    func rootTitle(_ url: URL) -> String { "Fixture server" }
}

@MainActor @Suite(.isolatedSettings) struct LocationPolicyTests {
    @Test func remoteFolderMenusDoNotOfferOpenPathAndTabsUseSharedNames() async throws {
        _ = NSApplication.shared
        let url = URL(string: "sftp://fixture-\(UUID().uuidString).invalid/work/")!
        RemoteFS.use(EmptyLocationProvider(), for: url)
        defer { RemoteFS.use(nil, for: url) }
        let tab = PorpoiseTab(url: url)
        let controller = MainWindowController(window: nil)
        controller.tabs = [tab]
        // Keep the fixture installed until the real browser's listing has completed.
        if tab.primary.model.isLoading {
            await withCheckedContinuation { continuation in
                let loaded = tab.primary.model.onLoaded
                tab.primary.model.onLoaded = { [weak model = tab.primary.model] in
                    model?.onLoaded = loaded; loaded?(); continuation.resume()
                }
            }
        }
        #expect(tab.primary.model.kind == .remote)
        #expect(tab.plainTitle == "work" && tab.iconName == "folder-remote" && tab.primary.canGoUp)
        let file = FileItem(url: url.appendingPathComponent("note.txt"), name: "note.txt", isDirectory: false)
        let menu = controller.contextMenu(for: file, in: tab.primary)
        #expect(!menu.items.contains { $0.title == "Open Path" || $0.title == "Open Path in New Tab" })
        tab.primary.model.searchResults = [file]
        let searchMenu = controller.contextMenu(for: file, in: tab.primary)
        #expect(searchMenu.items.contains { $0.title == "Open Path" })
    }

    @Test func breadcrumbNamesAndPrivateClipboardKeepRemoteIdentity() {
        _ = NSApplication.shared
        let account = UUID()
        let url = DropboxLocation(accountID: account, itemID: "id:opaque-folder").url
        let breadcrumb = BreadcrumbView(frame: .zero)
        breadcrumb.url = url
        let titles = breadcrumb.cloudCrumbs().map(\.title)
        #expect(!titles.isEmpty && titles.allSatisfy { $0 == "Dropbox" })
        #expect(!titles.joined().contains(account.uuidString) && !titles.joined().contains("opaque-folder"))
        let local = URL(fileURLWithPath: "/tmp/Local Folder")
        let remote = URL(string: "sftp://alice:fixture-secret@fixture.invalid/folder/")!
        let clipboard = SystemClipboard()
        clipboard.write([local, remote, url])
        let board = NSPasteboard(
            name: .init("app.porpoise.Porpoise.test-clipboard." + (ProcessInfo.processInfo.environment["PORPOISE_BRIDGE"] ?? "test")))
        #expect(board.string(forType: .string) == LocationNaming.clipboardText(for: [local, remote, url]))
        #expect(board.string(forType: .string)?.contains("fixture-secret") == false)
        clipboard.clear()
    }
}
