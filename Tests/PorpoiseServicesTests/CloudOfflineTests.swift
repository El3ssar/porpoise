import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct CloudOfflineTests {
    private func setup() throws -> (CloudOffline, FakeContentSource, Scratch) {
        let source = FakeContentSource(), scratch = try Scratch()
        let facade = CloudOffline(accounts: CloudAccounts(), root: scratch.url, source: { source.ref(for: $0) == nil ? nil : source })
        facade.operations = FileOperationsController()
        facade.operations.history = OperationHistory(file: scratch.url.appendingPathComponent("history"))
        return (facade, source, scratch)
    }
    @Test func plansPinsSnapshotsRemoveAndWipe() async throws {
        let (facade, source, scratch) = try setup()
        _ = scratch
        let folder = source.add("folder", folder: true), item = source.add("one", parent: "folder")
        let url = source.url(for: folder), fileURL = source.url(for: item)
        let plan: CloudKeepPlan = try await awaitCallback { continuation in
            facade.plan(keep: [url, url]) { continuation.resume(with: $0) }
        }
        #expect(plan.bytes == 5 && plan.items == 1 && plan.fits && !plan.needsConfirmation)
        #expect(CloudKeepPlan(bytes: 1_000_000_000, items: 1, available: 0).needsConfirmation)
        #expect(CloudKeepPlan(bytes: 0, items: 500, available: 0).needsConfirmation)
        // Not downloaded yet: the folder is in the cloud only, like its file.
        #expect(facade.state(for: url) == .cloudOnly)
        #expect(facade.state(for: fileURL) == .cloudOnly)
        let error: Error? = try await awaitCallback { continuation in
            facade.keep(true, [url]) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        await expectEventually { facade.details(for: fileURL).downloaded }
        #expect(facade.details(for: fileURL).kept)
        #expect(facade.details(for: fileURL).inheritedFrom == folder.name)
        #expect(facade.details(for: url).bytes == 5 && facade.details(for: url).items == 1)
        #expect(facade.usage(account: source.accountID).kept == 5)
        #expect(!facade.removeDownload([fileURL]).isEmpty)
        let stopped: Error? = try await awaitCallback { continuation in
            facade.keep(false, [url]) { continuation.resume(returning: $0) }
        }
        #expect(stopped == nil)
        await expectEventually { !facade.details(for: fileURL).kept }
        #expect(facade.usage(account: source.accountID).recent == 5)
        facade.recentLimit = 0
        await expectEventually { !facade.details(for: fileURL).downloaded }
        facade.recentLimit = nil
        let downloaded: Error? = try await awaitCallback { continuation in
            facade.downloadNow([fileURL]) { continuation.resume(returning: $0) }
        }
        #expect(downloaded == nil)
        await expectEventually { facade.details(for: fileURL).downloaded }
        // A copy that is only cached (not downloaded with Download) doesn't change the item's state.
        #expect(facade.state(for: fileURL) == .cloudOnly)
        facade.removeRecent(account: source.accountID)
        await expectEventually { !facade.details(for: fileURL).downloaded }
        facade.wipe(account: source.accountID)
        await expectEventually { facade.usage(account: source.accountID).recent == 0 }
        #expect(facade.details(for: URL(fileURLWithPath: "/tmp/local")).downloaded == false)
    }
    @Test func invalidActionsReturnErrorsAndCancellationIsSafe() async throws {
        let (facade, source, scratch) = try setup(); _ = scratch
        let invalid = URL(fileURLWithPath: "/tmp/local")
        let result: Result<CloudKeepPlan, Error> = try await awaitCallback { continuation in
            facade.plan(keep: [invalid]) { continuation.resume(returning: $0) }
        }
        if case .success = result { Issue.record("Local paths must not use the account store") }
        let error: Error? = try await awaitCallback { continuation in
            facade.downloadNow([invalid]) { continuation.resume(returning: $0) }
        }
        #expect(error as? CloudContentError == .unsupported)
        let folder = source.add("folder", folder: true)
        for n in 0..<20 { _ = source.add("item-\(n)", parent: "folder") }
        let cancel = facade.keep(true, [source.url(for: folder)])
        cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(source.downloads < 20)
        #expect(facade.removeDownload([invalid]).isEmpty)
    }
}

extension CloudOfflineTests {
    @Test func changePagesShareOneQuietAccountActivityAndRemoveRejectsHeldFiles() async throws {
        let (facade, source, scratch) = try setup(); _ = scratch
        let first = source.add("one"), second = source.add("two")
        let store = try facade.store(for: source)
        await expectEventually { source.onChanges != nil }
        let error: Error? = try await awaitCallback { continuation in
            facade.keep(true, [source.url(for: first), source.url(for: second)]) { continuation.resume(returning: $0) }
        }
        #expect(error == nil && facade.operations.activities.count == 1)
        source.delay = .milliseconds(100)
        var maximumQuiet = 0
        let observer = NotificationCenter.default.addObserver(
            forName: FileOperationsController.activityChanged, object: facade.operations, queue: .main
        ) { _ in
            maximumQuiet = max(
                maximumQuiet, facade.operations.activities.filter { $0.title.hasPrefix("Updating offline copies") && $0.state.isActive }.count)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let updated = source.add("one", text: "first update", revision: "r2")
        source.onChanges?(.init(changed: [updated]))
        await expectEventually { facade.operations.activities.contains { $0.title.hasPrefix("Updating offline copies") } }
        let other = source.add("two", text: "second update", revision: "r2")
        source.onChanges?(.init(changed: [other]))
        let deadline = Date().addingTimeInterval(10)
        while (await store.snapshot().entries["two"]?.item.revision != "r2"), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await expectEventually { facade.operations.activities.count == 1 }
        #expect(await store.snapshot().entries["one"]?.item.revision == "r2")
        #expect(await store.snapshot().entries["two"]?.item.revision == "r2")
        #expect(maximumQuiet == 1)
        facade.removalDenial = { $0 == source.url(for: updated) ? "Unsent changes" : nil }
        #expect(facade.removeDownload([source.url(for: updated)]) == ["Unsent changes"])
        #expect(facade.supports(source.url(for: updated)))
        #expect(!facade.supports(URL(fileURLWithPath: "/tmp/local")))
        var denied = updated; denied.canDownload = false; source.items["one"] = denied
        #expect(facade.keepDenial(for: source.url(for: updated)) != nil)
        facade.cacheLimit = 50
        #expect(facade.cacheLimit == 50)
        facade.wipe(account: source.accountID)
    }
}

extension CloudOfflineTests {
    @Test func serviceDistinguishesQueuedPinsBytesAndTransferErrors() async throws {
        let (facade, source, scratch) = try setup(); _ = scratch
        let item = source.add("one")
        let url = source.url(for: item)
        let service: CloudOfflineService = facade
        source.isOffline = true
        let error: Error? = try await awaitCallback { continuation in
            facade.keep(true, [url]) { continuation.resume(returning: $0) }
        }
        #expect(error != nil)
        await expectEventually { facade.details(for: url).kept }
        #expect(service.keep(for: url) == .direct)
        #expect(!service.hasLocalCopy(url) && service.state(for: url) == .cloudOnly)
        source.isOffline = false; source.delay = .milliseconds(100)
        let download = Task {
            try await awaitCallback { continuation in
                facade.downloadNow([url]) { continuation.resume(returning: $0) }
            }
        }
        await expectEventually {
            if case .downloading = service.state(for: url) { return true }; return false
        }
        #expect(try await download.value == nil)
        await expectEventually { service.state(for: url) == .local }
        #expect(service.hasLocalCopy(url))
        let bad = source.add("bad")
        source.bytes["bad"] = Data("wrong bytes".utf8)
        let failure: Error? = try await awaitCallback { continuation in
            facade.downloadNow([source.url(for: bad)]) { continuation.resume(returning: $0) }
        }
        #expect(failure as? CloudContentError == .checksum)
        await expectEventually {
            if case .error = service.state(for: source.url(for: bad)) { return true }; return false
        }
        #expect(!service.hasLocalCopy(source.url(for: bad)))
        facade.wipe(account: source.accountID)
    }
}
