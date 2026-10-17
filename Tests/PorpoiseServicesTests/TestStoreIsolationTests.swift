import Foundation
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
            ("offline copies", CloudOffline(root: nil).root), ("demo offline copies", DemoOfflineService().root),
            ("Drive metadata", DriveMetadataCache.root), ("remote files", RemoteFS.cacheParent),
            ("Android tools", AndroidTools.supportFolder), ("Dropbox", DropboxAccountStore.defaultDirectory),
        ]
        for (name, url) in roots {
            #expect(url.path.hasPrefix(temp) && !url.path.hasPrefix(library), "\(name): \(url.path)")
            #expect(url.path.contains("/porpoise-test-"), "\(name): \(url.path)")
        }
        #expect(Settings.supportFolder != Settings.cachesFolder)
    }
}
