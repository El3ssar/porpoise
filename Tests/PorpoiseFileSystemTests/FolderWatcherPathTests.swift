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

@Suite struct FolderWatcherRescanTests {
    private let watched: Set<String> = ["/w", "/w/sub", "/other"]
    private func flags(_ f: Int) -> FSEventStreamEventFlags { FSEventStreamEventFlags(f) }

    /// #19: coalesced, dropped and root-changed events read the folders they may cover again.
    @Test func eventsMacOSCouldNotNameRescanWhatTheyCover() {
        #expect(FolderWatcher.rescannedFolders(["/w/file"], flags: [flags(kFSEventStreamEventFlagItemCreated)], watched: watched).isEmpty)
        #expect(FolderWatcher.rescannedFolders(["/w"], flags: [flags(kFSEventStreamEventFlagMustScanSubDirs)], watched: watched) == ["/w", "/w/sub"])
        #expect(FolderWatcher.rescannedFolders(["/w/sub/deep"], flags: [flags(kFSEventStreamEventFlagMustScanSubDirs)], watched: watched).isEmpty)
        #expect(FolderWatcher.rescannedFolders([""], flags: [flags(kFSEventStreamEventFlagUserDropped)], watched: watched) == watched)
        #expect(FolderWatcher.rescannedFolders([""], flags: [flags(kFSEventStreamEventFlagKernelDropped)], watched: watched) == watched)
        #expect(FolderWatcher.rescannedFolders(["/other"], flags: [flags(kFSEventStreamEventFlagRootChanged)], watched: watched) == ["/other"])
    }

    /// A watched folder renamed under the view: the watcher reports it (the view then finds where it went).
    @Test func aWatchedFolderRenamedIsReported() async throws {
        let s = try Scratch()
        try s.folder("Watched")
        nonisolated(unsafe) var seen: Set<String> = []
        let lock = NSLock()
        let watcher = FolderWatcher { changed in lock.withLock { seen.formUnion(changed) } }
        defer { watcher.stop() }
        let watched = s.path("Watched")
        watcher.watch([watched])
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.moveItem(at: watched, to: s.path("Renamed"))
        #expect(await eventually { lock.withLock { seen.contains(watched.standardizedFileURL.path) } })
    }
}
