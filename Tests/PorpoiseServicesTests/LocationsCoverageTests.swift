import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// fd from build/search-tools (scripts/fetch-search-tools.sh), when they're there.
private let searchTools: FolderSearch.Tools? = {
    let dir = TestPaths.repo
        .appendingPathComponent("build/search-tools")
    let fd = dir.appendingPathComponent("fd").path
    let fm = FileManager.default
    return fm.isExecutableFile(atPath: fd) ? .init(fd: fd) : nil
}()

/// Apple's own apps: Spotlight indexes them on every Mac (when it's on), and they're never in the user's home.
private let systemApps = URL(fileURLWithPath: "/System/Applications")

// MARK: Search

/// One at a time: some of these hold Spotlight's queue (a Spotlight that never answers), which would make the others'
/// real queries give up. Other suites hold it too, now and then: real queries get time enough to wait for that.
@MainActor @Suite(.serialized) struct SpotlightUsingCoverageTests {
    @MainActor @Suite struct SearchRunnerCoverageTests {
        /// Runs `runner` until it says it's done; the names it found, sorted.
        private func finish(_ make: (@escaping ([FileItem], Bool) -> Void) -> SearchRunner, timeout: TimeInterval = eventualTimeout) async throws -> (
            runner: SearchRunner, names: [String], markedContentMatches: Bool
        ) {
            var result: [FileItem]?
            var marked = false
            weak var current: SearchRunner?
            let runner = make { items, done in
                guard done else { return }
                result = items
                marked = current?.snippetsMarkContentMatches ?? false
            }
            current = runner
            runner.start()
            try #require(await eventually(timeout) { result != nil })
            runner.stop()
            return (runner, (result ?? []).map(\.name).sorted(), marked)
        }

        /// Without fd the folder is walked: names in any case, at any depth.
        @Test func withoutToolsTheFolderIsWalkedForNames() async throws {
            let s = try Scratch()
            try s.file("deep/down/Budget 2026.txt", "x")
            try s.folder("budget folder")
            try s.file("other.txt", "budget inside")
            let (_, names, marked) = try await finish { update in
                let r = SearchRunner(text: "BUDGET", scope: s.url, contents: false, update: update)
                r.folderTools = nil
                return r
            }
            #expect(names == ["Budget 2026.txt", "budget folder"])
            #expect(!marked)
        }

        /// A tool that can't start doesn't mean nothing is there: the folder is walked instead.
        @Test(.enabled(if: searchTools != nil, "needs scripts/fetch-search-tools.sh"))
        func aToolThatCannotStartFallsBackToTheWalk() async throws {
            let s = try Scratch()
            try s.file("plan.md", "ask about the budget")
            let tools = try #require(searchTools)
            let (_, names, marked) = try await finish { update in
                let r = SearchRunner(text: "budget", scope: s.url, contents: true, update: update)
                r.folderTools = FolderSearch.Tools(fd: s.path("no-such-fd").path)
                return r
            }
            #expect(names == ["plan.md"] && !marked)
        }

        /// Walking with contents: files whose text matches too, and no folders (they have no contents).
        @Test func withoutToolsContentsAreReadAndFoldersLeftOut() async throws {
            let s = try Scratch()
            try s.file("deep/notes.txt", "the Budget is due")
            try s.folder("budget folder")
            try s.file("budget.md", "x")
            try s.file("unrelated.txt", "nothing")
            let (_, names, _) = try await finish { update in
                let r = SearchRunner(text: "budget", scope: s.url, contents: true, update: update)
                r.folderTools = nil
                return r
            }
            #expect(names == ["budget.md", "notes.txt"])
        }

        /// Stopped before the walk reports: nothing is shown afterwards.
        @Test func aStoppedWalkSaysNothing() async throws {
            let s = try Scratch()
            for i in 0..<50 { try s.file("f\(i)/match-\(i).txt") }
            var calls = 0
            let runner = SearchRunner(text: "match", scope: s.url, contents: true) { _, _ in calls += 1 }
            runner.folderTools = nil
            runner.start()
            runner.stop()
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(calls == 0)
        }

        /// With the tools, the snippets name exactly the content matches.
        @Test(.enabled(if: searchTools != nil, "needs scripts/fetch-search-tools.sh"))
        func withToolsSnippetsMarkContentMatches() async throws {
            let s = try Scratch()
            try s.file("plan.md", "ask about the budget")
            let (runner, names, marked) = try await finish { update in
                let r = SearchRunner(text: "budget", scope: s.url, contents: true, update: update)
                r.folderTools = searchTools
                return r
            }
            #expect(names == ["plan.md"])
            #expect(marked)
            #expect(runner.snippets[URL(fileURLWithPath: FilePath.canonical(s.path("plan.md").path))] == "ask about the budget")
        }

        @Test func spotlightPredicates() throws {
            #expect(
                SearchRunner.predicate(try SearchSpec("a b", contents: false)).predicateFormat
                    == #"kMDItemFSName LIKE[cd] "*a*" AND kMDItemFSName LIKE[cd] "*b*""#)
            let both = SearchRunner.predicate(try SearchSpec("x", contents: true)).predicateFormat
            #expect(both.contains("kMDItemTextContent LIKE[cd] \"*x*\"") && both.contains("kMDItemFSName LIKE[cd] \"*x*\""))
        }

        /// Searching everywhere asks Spotlight first; when it doesn't answer in time, the folders are searched instead.
        @Test func everywhereFallsBackToTheFoldersWhenSpotlightNeverAnswers() async throws {
            let s = try Scratch()
            let tag = "porpoisestall\(UUID().uuidString.prefix(6))"
            try s.file("deep/down/\(tag).txt")
            let resume = stallSpotlight()
            defer { resume() }
            let (_, names, _) = try await finish { update in
                let r = SearchRunner(text: tag, scope: s.url, contents: false, everywhere: true, update: update)
                r.gatheringTimeout = 0.3
                r.folderTools = nil
                return r
            }
            #expect(names == ["\(tag).txt"])
        }

        /// Spotlight doesn't index the temporary folder: it finds nothing there (or doesn't answer), and the folder is
        /// searched instead, so the file is found either way.
        @Test func everywhereSearchesTheFolderWhenSpotlightFindsNothing() async throws {
            let s = try Scratch()
            let tag = "porpoiseunindexed\(UUID().uuidString.prefix(6))"
            try s.file("a/\(tag).txt")
            let (_, names, _) = try await finish { update in
                let r = SearchRunner(text: tag, scope: s.url, contents: false, everywhere: true, update: update)
                r.folderTools = searchTools
                return r
            }
            #expect(names == ["\(tag).txt"])
        }

        /// Apple's apps, found by Spotlight (or, where it's off, by searching the folder): the same app either way.
        @Test func everywhereFindsAnIndexedApp() async throws {
            let (_, names, _) = try await finish { update in
                let r = SearchRunner(text: "Calculator", scope: systemApps, contents: false, everywhere: true, update: update)
                r.gatheringTimeout = 20
                r.folderTools = searchTools
                return r
            }
            #expect(names.contains("Calculator.app"))
        }

        /// A contents search everywhere: apps are packages, not folders, so they stay; they have no lines to show.
        @Test(.enabled(if: searchTools != nil, "needs scripts/fetch-search-tools.sh"))
        func everywhereContentSearchKeepsApps() async throws {
            let (runner, names, _) = try await finish(
                { update in
                    let r = SearchRunner(
                        text: "Terminal", scope: systemApps.appendingPathComponent("Utilities"), contents: true, everywhere: true,
                        update: update)
                    r.gatheringTimeout = 20
                    r.folderTools = searchTools
                    return r
                })
            #expect(names.contains("Terminal.app"))
            #expect(runner.snippets[systemApps.appendingPathComponent("Utilities/Terminal.app")] == nil)
        }
    }

    // MARK: Spotlight queries

    @MainActor @Suite struct SpotlightQueryCoverageTests {
        /// Every event a query reports, as text.
        private final class Log {
            var events: [String] = []
            var paths: [String] = []
        }

        private func record(_ log: Log) -> (SpotlightQuery.Event) -> Void {
            { event in
                switch event {
                case .progress: log.events.append("progress")
                case .gathered(let p): log.events.append("gathered"); log.paths = p
                case .updated: log.events.append("updated")
                case .unavailable: log.events.append("unavailable")
                }
            }
        }

        private func finished(_ log: Log) -> Bool { log.events.contains { $0 == "gathered" || $0 == "unavailable" } }

        /// A query that Spotlight answers ends with the paths (at most `limit`); one it doesn't, with `.unavailable`.
        /// Either way gathering ends once, and nothing comes after it for a query that isn't live.
        @Test func aQueryEndsOnceWithItsPaths() async throws {
            let log = Log()
            let q = SpotlightQuery(
                predicate: NSPredicate(format: "kMDItemFSName == %@", "Calculator.app"), scopes: [systemApps], limit: 10, timeout: 20,
                handler: record(log))
            q.start()
            defer { q.stop() }
            #expect(await eventually { finished(log) })
            #expect(log.events.filter { $0 == "gathered" || $0 == "unavailable" }.count == 1)
            if log.events.last == "gathered" {
                #expect(log.paths == [systemApps.appendingPathComponent("Calculator.app").path])
            }
        }

        @Test func resultsStopAtTheLimit() async throws {
            let log = Log()
            let q = SpotlightQuery(
                predicate: NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*.app"), scopes: [systemApps], limit: 2, live: true,
                timeout: 20, handler: record(log))
            q.start()
            #expect(await eventually { finished(log) })
            q.stop()
            #expect(log.paths.count <= 2)
            if log.events.contains("gathered") { #expect(log.paths.count == 2) }
            let after = log.events.count
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(log.events.count == after)  // stopped: nothing more
        }

        /// A live query reports its results again when Spotlight says they changed (only after gathering).
        @Test func aLiveQueryReportsUpdates() async throws {
            let log = Log()
            let q = SpotlightQuery(
                predicate: NSPredicate(format: "kMDItemFSName == %@", "Calculator.app"), scopes: [systemApps], limit: 10, live: true,
                timeout: 20, handler: record(log))
            q.start()
            defer { q.stop() }
            #expect(await eventually { finished(log) })
            guard log.events.last == "gathered" else { return }  // Spotlight is off here: no updates to report
            // What NSMetadataQuery posts on its queue when an item changes.
            SpotlightQuery.queue.addOperation {
                NotificationCenter.default.post(
                    name: .NSMetadataQueryDidUpdate, object: q.query, userInfo: [NSMetadataQueryUpdateChangedItemsKey: []])
            }
            #expect(await eventually { log.events.last == "updated" })
        }

        /// Recent Files: when Spotlight doesn't answer, the list is shown empty (after the default wait).
        @Test func recentFilesAreEmptyWhenSpotlightNeverAnswers() async throws {
            let resume = stallSpotlight()
            defer { resume() }
            var files: [FileItem]?
            let q = RecentFilesQuery { files = $0.items }
            #expect(await eventually { files != nil })
            #expect(files?.isEmpty == true)
            _ = q
        }
    }
}

// MARK: Cloud actions

@MainActor @Suite struct CloudActionsCoverageTests {
    /// Waits for the folders-changed notification that names `path`.
    private func changed(_ path: String, after action: () -> Void) async -> Bool {
        // Posted on whatever thread changed the folders, read here on the main actor.
        let seen = Locked(Set<String>())
        let token = NotificationCenter.default.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: nil) { n in
            if let p = n.userInfo?["paths"] as? Set<String> { seen.change { $0.formUnion(p) } }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        action()
        return await eventually { seen.value.contains(FilePath.entry(path)) }
    }

    /// Files that aren't in the cloud: nothing to download, but the views are told to look again.
    @Test func downloadingLocalItemsJustRefreshes() async throws {
        let s = try Scratch()
        let f = try s.file("a.txt", "x")
        try s.file("folder/inner/b.txt", "y")
        let folder = s.path("folder")
        #expect(await changed(folder.path) { CloudActions.download([f, folder]) })
        #expect(s.read("a.txt") == "x" && s.read("folder/inner/b.txt") == "y")
    }

    /// Removing the download of a local file fails, and says which.
    @Test func evictingALocalFileFails() async throws {
        let s = try Scratch()
        let f = try s.file("local.txt", "x")
        var failed: [String] = []
        #expect(await changed(f.path) { failed = CloudActions.evict([f]) })
        #expect(failed.count == 1 && failed[0].hasPrefix("“local.txt”: "))
        #expect(s.read("local.txt") == "x")
        #expect(CloudActions.evict([]).isEmpty)
    }

    /// Finder's own preference, only read.
    @Test func trashAutoEmptyIsReadable() {
        let value = TrashInfo.autoEmpty
        #expect(value == true || value == false)
    }
}

// MARK: Detected places

@MainActor @Suite struct PlacesDetectionCoverageTests {
    /// Cloud folders and Android phones (adb replaced by a script) show up, and go when they're gone.
    @Test func cloudFoldersAndPhonesAreDetected() async throws {
        let s = try Scratch()
        let drive = try s.folder("CloudStorage/GoogleDrive-me@example.com")
        let adb = try RecordingTool()
        try adb.reply("List of devices attached\nR58N123 device usb:1-1 product:x model:Galaxy_S21 device:o1s\n")
        let m = PlacesModel(storeURL: nil)
        m.cloudStorageRoot = s.path("CloudStorage")
        m.adbTool = { adb.path }
        defer { m.isActive = false }  // no polling timer left behind

        m.refreshDetected()
        #expect(m.titles(in: .remote).contains("Google Drive (me@example.com)"))
        #expect(await eventually { m.titles(in: .removable).contains("Galaxy S21") })
        let phone = try #require(m.allEntries.first { $0.title == "Galaxy S21" })
        #expect(phone.url.absoluteString == "adb://R58N123/sdcard/" && phone.icon == "smartphone")
        #expect(adb.calls.first?.args == ["devices", "-l"])

        // Bookmarked: listed once, as the bookmark.
        m.add(drive, title: "Drive")
        #expect(m.allEntries.filter { $0.url.standardizedFileURL == drive.standardizedFileURL }.map(\.title) == ["Drive"])

        // In the background nothing is polled; back in front, the phone has gone.
        m.isActive = false
        try adb.reply("List of devices attached\n")
        m.isActive = true
        #expect(await eventually { !m.titles(in: .removable).contains("Galaxy S21") })

        // No longer bookmarked: detected again; and once the folder has gone, not at all.
        m.remove(try #require(m.userEntries.first { $0.title == "Drive" }))
        #expect(m.detected.contains { $0.title == "Google Drive (me@example.com)" })
        try FileManager.default.removeItem(at: drive)
        m.refreshDetected()
        #expect(!m.detected.contains { $0.section == .remote })
    }

    /// Without adb no phones are polled.
    @Test func withoutAdbNoPhones() throws {
        let s = try Scratch()
        let m = PlacesModel(storeURL: nil)
        m.cloudStorageRoot = s.path("none")
        m.adbTool = { nil }
        m.refreshDetected()
        m.isActive = false
        #expect(m.detected.isEmpty)
        // The app's own model polls only once the app says it's in front: in a test process, never (its adb runs
        // landed in another test's recording adb).
        #expect(!PlacesModel.shared.isActive)
    }
}
