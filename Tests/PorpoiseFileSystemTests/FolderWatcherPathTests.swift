import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct FolderWatcherPathTests {
    @Test func watcherReportsParentOfChangedItems() {
        let watched: Set<String> = ["/w", "/w/sub"]
        #expect(FolderWatcher.changedFolders(["/w/file"], watched: watched) == ["/w"])
        #expect(FolderWatcher.changedFolders(["/w/sub"], watched: watched) == ["/w/sub"])
        #expect(FolderWatcher.changedFolders(["/elsewhere/x"], watched: watched).isEmpty)
    }
}
