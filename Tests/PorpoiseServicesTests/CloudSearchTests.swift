import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The search bar in a cloud folder: the service's pages one after another, growing results, a limit, errors in words.
@MainActor @Suite(.isolatedSettings) struct CloudSearchTests {
    private func setup() throws -> (CloudAccounts, DemoCloudBackend, URL) {
        let backend = DemoCloudBackend()
        _ = backend.connect(.googleDrive, openBrowser: { _ in }, done: { _ in })
        backend.finishSignIn(CloudAccount(id: "a1", email: "avery@example.com", displayName: "Avery"))
        let accounts = CloudAccounts()
        accounts.backend = backend
        return (accounts, backend, try #require(accounts.url("a1", root: .myDrive)))
    }

    private func items(_ names: [String], in folder: URL) -> [FileItem] {
        names.map { FileItem(url: folder.appendingPathComponent($0), name: $0, isDirectory: false) }
    }

    @Test func pagesArriveInTurnAndTheResultsGrow() throws {
        let (accounts, backend, folder) = try setup()
        backend.searchPages = [items(["a", "b"], in: folder), [], items(["b", "c"], in: folder)]
        backend.holdsSearches = true
        let run = CloudSearch("report", in: folder, everywhere: true, contents: true, accounts: accounts)
        var calls: [([String], Bool)] = []
        run.onResults = { calls.append(($0.map(\.name), $1)) }
        run.start()
        #expect(calls.isEmpty && run.serviceTitle == "Google Drive")
        backend.answerSearch()
        backend.answerSearch()
        backend.answerSearch()
        // An empty page in between keeps going; a result listed again shows once.
        #expect(calls.map(\.0) == [["a", "b"], ["a", "b"], ["a", "b", "c"]] && calls.map(\.1) == [false, false, true])
        #expect(backend.searches.map(\.page) == [nil, "1", "2"])
        #expect(backend.searches.allSatisfy { $0.text == "report" && $0.folder == folder && $0.everywhere && $0.contents })
        #expect(run.isDone && run.summary == "3 items found in Google Drive.")
    }

    @Test func stopsAtTheLimitAndWhenStopped() throws {
        let (accounts, backend, folder) = try setup()
        backend.searchPages = [items(["a", "b"], in: folder), items(["c", "d"], in: folder), items(["e"], in: folder)]
        let run = CloudSearch("x", in: folder, limit: 3, accounts: accounts)
        run.start()
        #expect(run.items.map(\.name) == ["a", "b", "c"] && run.isTruncated && run.isDone)
        #expect(backend.searches.count == 2)
        #expect(run.summary == "Showing the first 3 items found in Google Drive. Type more to narrow the search.")

        backend.holdsSearches = true
        let stopped = CloudSearch("x", in: folder, accounts: accounts)
        var called = false
        stopped.onResults = { _, _ in called = true }
        stopped.start()
        stopped.stop()
        backend.answerSearch()
        #expect(!called && !stopped.isDone)
    }

    @Test func failuresAndUnsupportedServicesSayWhy() throws {
        let (accounts, backend, folder) = try setup()
        let unsupported = CloudSearch("x", in: folder, accounts: accounts)
        unsupported.start()
        #expect(unsupported.isDone && unsupported.summary == "Searching isn’t available in Google Drive yet.")

        backend.searchPages = [items(["a"], in: folder), items(["b"], in: folder)]
        backend.searchError = CloudEditError.denied("You’re offline.")
        let failed = CloudSearch("x", in: folder, accounts: accounts)
        failed.start()
        #expect(failed.items.isEmpty && failed.summary == "Couldn’t search Google Drive: You’re offline.")

        backend.holdsSearches = true
        let partly = CloudSearch("x", in: folder, accounts: accounts)
        partly.start()
        backend.answerSearch()
        backend.searchError = CloudEditError.denied("Lost the connection.")
        backend.answerSearch()
        #expect(partly.items.map(\.name) == ["a"] && partly.summary == "1 item found in Google Drive; the rest couldn’t be loaded.")
        // Without the account, the service is still known from the location; with neither, "the cloud".
        #expect(CloudSearch("x", in: folder, accounts: CloudAccounts()).serviceTitle == "Google Drive")
        #expect(CloudSearch("x", in: URL(string: "cloud-disconnected:///")!, accounts: CloudAccounts()).serviceTitle == "the cloud")
        let nothing = CloudSearch("x", in: folder, accounts: CloudAccounts())
        nothing.start()
        #expect(nothing.summary == "Searching isn’t available in Google Drive yet.")
    }

    @Test func emptyResults() throws {
        let (accounts, backend, folder) = try setup()
        backend.searchPages = [[]]
        let run = CloudSearch("zzz", in: folder, accounts: accounts)
        run.start()
        #expect(run.summary == "No items found in Google Drive.")
    }
}
