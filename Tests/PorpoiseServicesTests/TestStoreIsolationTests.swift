import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A test instance (PORPOISE_DEFAULTS_SUITE) never reads or writes Porpoise's real data or caches: every store
/// lives in the instance's own folder.
@Suite(.isolatedSettings) struct TestStoreIsolationTests {
    @MainActor @Test func everyStoreLivesInTheTestsOwnFolder() throws {
        #expect(Settings.isTesting)
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let temp = FileManager.default.temporaryDirectory.path
        let roots: [(String, URL)] = [
            ("support", Settings.supportFolder), ("caches", Settings.cachesFolder),
            ("Places", PlacesModel.defaultFile), ("shelves", ShelfStore.defaultFile), ("jobs", JournalStore.defaultFolder),
            ("history", OperationHistory.defaultFile), ("templates", TemplateStore().directory), ("icons", IconTheme.userIconsDirectory),
            ("offline copies", CloudOffline(root: nil).root), ("demo offline copies", DemoOfflineService().root),
            ("Drive metadata", DriveMetadataCache.root), ("remote files", RemoteFS.cacheParent),
            ("Android tools", AndroidTools.supportFolder), ("Dropbox", DropboxAccountStore.defaultDirectory),
        ]
        for (name, url) in roots {
            #expect(url.path.hasPrefix(temp) && !url.path.hasPrefix(library), "\(name): \(url.path)")
            #expect(url.path.contains("/porpoise-test-"), "\(name): \(url.path)")
        }
        #expect(Settings.supportFolder != Settings.cachesFolder)
        #expect(PlacesModel.defaultFile == Settings.supportFolder.appendingPathComponent("places.json"))
        #expect(ShelfStore.defaultFile == Settings.supportFolder.appendingPathComponent("shelves.json"))
        #expect(JournalStore.defaultFolder == Settings.supportFolder.appendingPathComponent("Jobs"))
        #expect(OperationHistory.defaultFile == Settings.supportFolder.appendingPathComponent("history.jsonl"))
        #expect(TemplateStore().directory == Settings.supportFolder.appendingPathComponent("Templates", isDirectory: true))
        let explicit = URL(fileURLWithPath: "/fixture/explicit-templates")
        #expect(TemplateStore(directory: explicit).directory == explicit)
    }
}
