import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Download Now / Keep Downloaded / Remove Download: which the menus offer for a selection, what they do, and the one
/// badge an item shows.
@MainActor @Suite(.serialized, .isolatedSettings) struct CloudCommandsTests {
    let base = "gdrive://00000000-0000-0000-0000-000000000001/my-drive/"
    func url(_ id: String, folder: Bool = false) -> URL { URL(string: base + id + (folder ? "/" : ""))! }
    func file(_ id: String) -> FileItem { FileItem(url: url(id), name: id, isDirectory: false) }
    func folder(_ id: String) -> FileItem { FileItem(url: url(id, folder: true), name: id, isDirectory: true) }

    /// Runs `body` with `demo` as the app's offline service.
    func with(_ demo: DemoOfflineService, _ body: () throws -> Void) rethrows {
        let saved = CloudOfflineHub.service
        CloudOfflineHub.service = demo
        defer { CloudOfflineHub.service = saved }
        try body()
    }

    func available(_ items: [FileItem], _ demo: DemoOfflineService) -> CloudCommands.Available {
        CloudCommands.available(for: items) { (demo.state(for: $0.url), true) }
    }

    // MARK: Badges

    @Test func oneBadgeAnEditComesFirst() {
        #expect(CloudBadgeKind.resolve(.local, edit: nil) == .none)
        #expect(CloudBadgeKind.resolve(.cloudOnly, edit: nil) == .cloud(.cloudOnly))
        #expect(CloudBadgeKind.resolve(.local, edit: .editing) == .edit(.editing))
        #expect(CloudBadgeKind.resolve(.error("x"), edit: .conflict) == .edit(.conflict))
        #expect(CloudBadgeKind.resolve(.downloading(0.4), edit: nil).cloudState == .downloading(0.4))
        #expect(CloudBadgeKind.resolve(.cloudOnly, edit: .saving).cloudState == nil)
    }

    @Test func statesSayWhatTheyAre() {
        #expect(CloudState.downloading(0.42).help == "Downloading… 42%" && CloudState.downloading(nil).help == "Downloading…")
        #expect(CloudState.uploading(0.5).progress == 0.5 && CloudState.uploading(nil).isTransferring)
        #expect(!CloudState.cloudOnly.isTransferring && CloudState.local.progress == nil)
        #expect(CloudState.error("The disk isn’t connected").help == "The disk isn’t connected")
        #expect(CloudState.error("x").symbol == "exclamationmark.icloud" && CloudState.local.symbol == nil)
        #expect(CloudState.cloudOnly.symbol == "icloud.and.arrow.down" && CloudState.local.help.isEmpty)
    }

    /// Two states: on this Mac (downloaded, no badge) or in the cloud only (a cached copy doesn't count), folders too.
    @Test func accountItemsBadgeFromTheService() {
        let demo = DemoOfflineService()
        demo.set(url("a"), "kept")
        demo.set(url("b"), "downloading:0.4")
        demo.set(url("d"), "downloaded")
        demo.set(url("f", folder: true), "kept")
        demo.set(url("i"), "inherited:Photos")
        with(demo) {
            let m = DirectoryModel(location: URL(string: base)!)
            #expect(m.shownCloud(for: file("a")) == (.local, true))
            #expect(m.cloud(for: file("b")).state == .downloading(0.4))
            #expect(m.shownCloud(for: file("c")).state == .cloudOnly)
            #expect(m.shownCloud(for: file("d")).state == .cloudOnly)
            #expect(m.shownCloud(for: file("i")).state == .local)
            #expect(m.shownCloud(for: folder("f")).state == .local)
            #expect(m.shownCloud(for: folder("g")).state == .cloudOnly)
            demo.unsupported = [url("c")]
            #expect(m.shownCloud(for: file("c")) == (.local, false))
        }
    }

    // MARK: What the menus offer

    @Test func cloudOnlyItemsOfferDownload() {
        let demo = DemoOfflineService()
        demo.set(url("d"), "downloaded")
        with(demo) {
            let a = available([file("a")], demo)
            #expect(a.download && a.downloadEnabled && a.downloadTitle == "Download" && !a.removeDownload)
            // A cached copy is still in the cloud only.
            let cached = available([file("d")], demo)
            #expect(cached.download && !cached.removeDownload)
            #expect(available([folder("f")], demo).download)
        }
    }

    @Test func downloadedAndMixedSelections() {
        let demo = DemoOfflineService()
        demo.set(url("a"), "kept")
        with(demo) {
            let here = available([file("a")], demo)
            #expect(!here.download && here.removeDownload && here.removeEnabled)
            let mixed = available([file("a"), file("c")], demo)
            #expect(mixed.download && mixed.removeDownload)
        }
    }

    @Test func downloadedWithAFolderOnlyThatFolderCanBeRemoved() {
        let demo = DemoOfflineService()
        demo.set(url("a"), "inherited:Photos")
        demo.set(url("b"), "inherited:Photos")
        with(demo) {
            let a = available([file("a"), file("b")], demo)
            #expect(!a.download && a.removeDownload && !a.removeEnabled)
            #expect(a.reason == "On this Mac because “Photos” is downloaded.")
            // With an item of its own, the selection can be changed.
            demo.set(url("c"), "kept")
            #expect(available([file("a"), file("c")], demo).removeEnabled)
        }
    }

    @Test func itemsTheOwnerLockedSayWhy() {
        let demo = DemoOfflineService()
        demo.denials[url("a")] = "The owner turned off downloading."
        with(demo) {
            let a = available([file("a")], demo)
            #expect(a.download && !a.downloadEnabled && a.reason == "The owner turned off downloading.")
        }
    }

    @Test func iCloudKeepsDownloadNow() {
        let demo = DemoOfflineService()
        with(demo) {
            let local = FileItem(url: URL(fileURLWithPath: "/tmp/x.txt"), name: "x.txt", isDirectory: false)
            let only = CloudCommands.available(for: [local]) { _ in (.cloudOnly, true) }
            #expect(only.download && only.downloadTitle == "Download Now" && !only.removeDownload)
            let here = CloudCommands.available(for: [local]) { _ in (.local, true) }
            #expect(!here.download && here.removeDownload)
            #expect(CloudCommands.available(for: [local]) { _ in (.local, false) }.isEmpty)
            // Virtual rows (Shared with me) have no offline commands.
            demo.unsupported = [url("v")]
            #expect(available([file("v")], demo).isEmpty)
        }
        // No offline service: nothing for account items.
        let saved = CloudOfflineHub.service
        CloudOfflineHub.service = nil
        defer { CloudOfflineHub.service = saved }
        #expect(CloudCommands.available(for: [file("a")]) { _ in (.cloudOnly, true) }.isEmpty)
    }

    // MARK: Doing them

    @Test func commandsGoToTheService() {
        let demo = DemoOfflineService()
        with(demo) {
            // Download hands account items not yet on this Mac back to the app, which keeps them (counted first).
            demo.set(url("b"), "kept")
            #expect(CloudCommands.downloadNow([url("a"), url("b")]) == [url("a")])
            demo.keep([url("a")])
            #expect(demo.state(for: url("a")) == .local)
            // Remove Download returns what stayed.
            demo.refusals[url("b")] = "“b” has changes not in Google Drive yet."
            #expect(CloudCommands.removeDownload([url("a"), url("b")]) == ["“b” has changes not in Google Drive yet."])
            #expect(demo.state(for: url("a")) == .cloudOnly && demo.state(for: url("b")) == .local)
        }
    }

    @Test func notificationsNameTheItems() {
        let demo = DemoOfflineService()
        var seen: [URL]?
        let o = NotificationCenter.default.addObserver(forName: CloudOfflineHub.changed, object: nil, queue: nil) { seen = CloudOfflineHub.urls($0) }
        defer { NotificationCenter.default.removeObserver(o) }
        demo.keep([url("a")])
        #expect(seen == [url("a")])
    }

    @Test func plansAnswerAndCanBeHeld() {
        let demo = DemoOfflineService()
        var got: CloudKeepPlan?
        _ = demo.plan(keep: [url("a"), url("b")]) { got = try? $0.get() }
        #expect(got == CloudKeepPlan(bytes: 2 << 20, items: 2, available: 100 << 30, fits: true))
        demo.holdsPlans = true
        got = nil
        _ = demo.plan(keep: [url("a")]) { got = try? $0.get() }
        #expect(got == nil)
        demo.answerPlan()
        #expect(got?.items == 1)
        demo.holdsPlans = false
        demo.planError = CloudContentError.offline
        var failed = false
        _ = demo.plan(keep: [url("a")]) { if case .failure = $0 { failed = true } }
        #expect(failed)
    }

    // MARK: Words

    @Test func bigFoldersAskFirst() {
        let small = CloudKeepPlan(bytes: 200 << 20, items: 40, available: 50 << 30, fits: true)
        #expect(!small.needsConfirmation)
        #expect(CloudKeepPlan(bytes: 2 << 30, items: 3, available: 50 << 30, fits: true).needsConfirmation)
        #expect(CloudKeepPlan(bytes: 1 << 20, items: 500, available: 50 << 30, fits: true).needsConfirmation)
        let text = CloudCommands.planText(CloudKeepPlan(bytes: 13_300_000_000, items: 3210, available: 48_000_000_000, fits: true), folder: true)
        #expect(text.contains("\(FileFormat.count(3210)) items") && text.contains("available on this Mac") && text.hasSuffix("will download too."))
        let full = CloudCommands.planText(CloudKeepPlan(bytes: 13_300_000_000, items: 3210, available: 9_100_000_000, fits: false), folder: true)
        #expect(full.hasPrefix("Needs ") && full.contains("you have"))
        #expect(CloudCommands.planText(CloudKeepPlan(bytes: 1, items: 1, available: 9, fits: true), folder: false).contains("1 item."))
    }

    @Test func propertiesSayWhatIsOnThisMac() {
        var d = CloudOfflineDetails()
        #expect(CloudCommands.summaryText(d, folder: false, provider: "Google Drive") == "In Google Drive only")
        d.downloaded = true
        #expect(CloudCommands.summaryText(d, folder: false, provider: "Google Drive") == "In Google Drive only")  // a cached copy
        d.kept = true
        #expect(CloudCommands.summaryText(d, folder: false, provider: "Google Drive") == "Downloaded")
        d.bytes = 24_100_000
        #expect(CloudCommands.summaryText(d, folder: false, provider: "Google Drive").hasPrefix("Downloaded · "))
        d.export = "docx"
        #expect(CloudCommands.summaryText(d, folder: false, provider: "Google Drive").hasSuffix("as .docx, read-only offline"))
        var waiting = CloudOfflineDetails()
        waiting.kept = true
        #expect(CloudCommands.summaryText(waiting, folder: false, provider: "Google Drive") == "Waiting to download")
        var f = CloudOfflineDetails()
        f.inheritedFrom = "Photos"
        #expect(CloudCommands.summaryText(f, folder: true, provider: "Google Drive") == "Downloaded · with “Photos”")
        f.items = 812
        f.totalItems = 1020
        f.bytes = 3_200_000_000
        #expect(
            CloudCommands.summaryText(f, folder: true, provider: "Google Drive")
                == "Downloading · 812 of \(FileFormat.count(1020)) items · with “Photos”")
        f.items = 1020
        #expect(CloudCommands.summaryText(f, folder: true, provider: "Google Drive").hasPrefix("Downloaded · "))
        f.progress = 0.41
        #expect(CloudCommands.summaryText(f, folder: true, provider: "Google Drive") == "Downloading 41 %")
        f.error = "Not enough space on this Mac."
        #expect(CloudCommands.summaryText(f, folder: true, provider: "Google Drive") == "Not enough space on this Mac.")
        #expect(CloudCommands.summaryText(CloudOfflineDetails(), folder: true, provider: "Dropbox") == "In Dropbox only")
    }

    @Test func settingsAndSignOutWords() {
        #expect(CloudCommands.signOutLine(bytes: 0, provider: "Google Drive") == nil)
        let line = CloudCommands.signOutLine(bytes: 2_300_000_000, provider: "Google Drive")
        #expect(line?.hasPrefix("The ") == true && line?.hasSuffix("Your files stay in Google Drive.") == true)
        let u = CloudCommands.usageText(CloudOfflineUsage(kept: 3_100_000_000, recent: 820_000_000), account: "Google Drive · me@x.com")
        #expect(u.hasPrefix("Google Drive · me@x.com: ") && u.contains(" downloaded · ") && u.hasSuffix("of recently opened files"))
        #expect(!CloudCommands.usageText(CloudOfflineUsage(kept: 1, recent: 0), account: "a").contains("recently"))
        #expect(CloudCommands.cacheLimits.map(\.bytes).last == .some(nil) && CloudCommands.cacheLimits[1].bytes == 5 << 30)
        #expect(CloudCommands.cacheLimits.map(\.title) == [1, 5, 10, 25].map { FileFormat.byteLimitTitle(Int64($0) << 30) } + ["No limit"])
    }

    @Test func demoWordsSetStates() {
        let demo = DemoOfflineService()
        demo.set(url("a"), "uploading:0.6")
        #expect(demo.state(for: url("a")) == .uploading(0.6))
        demo.set(url("a"), "error:Checksum failed")
        #expect(demo.state(for: url("a")) == .error("Checksum failed") && demo.details(for: url("a")).error == "Checksum failed")
        demo.set(url("a"), "cloudonly")
        #expect(demo.state(for: url("a")) == .cloudOnly)
        demo.set(url("a"), "local")
        #expect(demo.state(for: url("a")) == .local)
        demo.usages["acct"] = CloudOfflineUsage(kept: 5, recent: 7)
        demo.removeRecent(account: "acct")
        #expect(demo.usage(account: "acct").recent == 0 && demo.usage(account: "acct").kept == 5)
        #expect(demo.keepDenial(for: url("a")) == nil && demo.supports(url("a")) && !demo.supports(URL(fileURLWithPath: "/tmp")))
    }
}
