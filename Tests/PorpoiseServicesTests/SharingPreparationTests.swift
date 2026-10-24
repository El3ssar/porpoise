import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct SharingPreparationTests {
    @Test func quitDrainsRetainedCopiesBeforeItsMainQueueReply() async throws {
        let scratch = try Scratch(), folder = try scratch.folder("retained")
        let file = try scratch.file("retained/file", "private temporary copy")
        let prepared = PreparedSharingItems(urls: [file], folder: folder)
        prepared.cleanup(after: 600)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await awaitCallback("sharing quit cleanup") { continuation in
            let waiting = PreparedSharingItems.cleanupBeforeQuit {
                #expect(Thread.isMainThread)
                #expect(!FileManager.default.fileExists(atPath: folder.path))
                continuation.resume()
            }
            #expect(waiting)
        }
        #expect(!PreparedSharingItems.cleanupBeforeQuit { Issue.record("An empty cleanup queue must not reply asynchronously") })
    }
    @Test func successfulSharingGraceSurvivesOwnerReleaseAndDuplicateCleanup() async throws {
        let scratch = try Scratch(), folder = try scratch.folder("staged")
        let file = try scratch.file("staged/file", "sharingd can still read this")
        var prepared: PreparedSharingItems? = PreparedSharingItems(urls: [file], folder: folder)
        let start = ContinuousClock.now
        prepared?.cleanup(after: 1)
        prepared?.cleanup()
        prepared = nil  // Deinitialization must not shorten the already scheduled grace period.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await eventually { !FileManager.default.fileExists(atPath: folder.path) })
        #expect(start.duration(to: .now) >= .seconds(1))
    }
    @Test func localItemsPassThroughWithoutTemporaryCopies() async throws {
        let scratch = try Scratch()
        let urls = [try scratch.file("quote'\" 日本語\n.txt", "local"), try scratch.folder("folder")]
        let controller = FileOperationsController()
        let prepared = try await controller.prepareForSharing(urls)
        #expect(prepared.urls == urls && prepared.folder == nil && controller.activities.isEmpty)
        prepared.cleanup()
        #expect(FileManager.default.fileExists(atPath: urls[0].path))
        #expect(!SharingPreparation.supports([]))
        #expect(!SharingPreparation.supports([urls[0], URL(string: "https://example.invalid/file")!]))
        #expect(!SharingPreparation.supports([URL(string: "recent:/files")!]))
    }

    @Test func mixedSelectionAndEqualRemoteNamesKeepEveryOriginal() async throws {
        let scratch = try Scratch()
        let server = try scratch.folder("server")
        try scratch.file("server/one/same 日本語\n'\".txt", "first")
        try scratch.file("server/two/same 日本語\n'\".txt", "second")
        try scratch.file("server/tree/deep/file.txt", "nested")
        let root = URL(string: "sftp://share-\(UUID().uuidString).invalid/")!
        RemoteFS.use(CountingTransferProvider(root: server), for: root)
        defer { RemoteFS.use(nil, for: root) }
        let first = root.appendingPathComponent("one/same 日本語\n'\".txt")
        let second = root.appendingPathComponent("two/same 日本語\n'\".txt")
        let local = try scratch.file("local.txt", "local")
        let urls = [first, local, second, root.appendingPathComponent("tree", isDirectory: true)]
        Settings.shared.transferExclusions = "*"  // Explicit selection is complete, regardless of copy-job exclusions.
        let controller = FileOperationsController()
        let prepared = try await controller.prepareForSharing(urls)
        let folder = try #require(prepared.folder)
        #expect(prepared.urls.count == urls.count && prepared.urls[1] == local)
        #expect(prepared.urls[0].lastPathComponent == first.lastPathComponent && prepared.urls[2].lastPathComponent == first.lastPathComponent)
        #expect(prepared.urls[0] != prepared.urls[2])
        #expect(try String(contentsOf: prepared.urls[0], encoding: .utf8) == "first")
        #expect(try String(contentsOf: prepared.urls[2], encoding: .utf8) == "second")
        #expect(try String(contentsOf: prepared.urls[3].appendingPathComponent("deep/file.txt"), encoding: .utf8) == "nested")
        #expect(scratch.read("server/one/same 日本語\n'\".txt") == "first")
        #expect(scratch.read("server/two/same 日本語\n'\".txt") == "second")
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o700)
        let activity = try #require(controller.activities.last)
        #expect(activity.title == "Preparing to share" && activity.state == .completed)
        #expect(activity.progress?.doneItems == urls.count && activity.progress?.doneBytes == activity.progress?.totalBytes)
        prepared.cleanup(); prepared.cleanup()
        #expect(await eventually { !FileManager.default.fileExists(atPath: folder.path) })
        #expect(scratch.read("local.txt") == "local")
    }

    @Test func failureAndCancellationLeaveNoPartialSelection() async throws {
        let scratch = try Scratch()
        let server = try scratch.folder("server")
        try scratch.file("server/good.txt", "good")
        let root = URL(string: "sftp://share-\(UUID().uuidString).invalid/")!
        RemoteFS.use(CountingTransferProvider(root: server), for: root)
        defer { RemoteFS.use(nil, for: root) }
        let destination = try scratch.folder("staging")
        let urls = [root.appendingPathComponent("good.txt"), root.appendingPathComponent("missing.txt")]
        let control = JobControl(policy: TransferPolicy(retries: 0))
        await #expect(throws: (any Error).self) {
            try await offThePool {
                try SharingPreparation.prepare(
                    urls, control: control, batchID: UUID(), temporaryDirectory: destination, progress: { _ in }, notice: { _ in })
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let cancelled = JobControl(); cancelled.cancel()
        await #expect(throws: (any Error).self) {
            try await offThePool {
                try SharingPreparation.prepare(
                    urls, control: cancelled, batchID: UUID(), temporaryDirectory: destination, progress: { _ in }, notice: { _ in })
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(scratch.read("server/good.txt") == "good")
    }

    @Test(arguments: [true, false]) func cancellingAnInFlightPreparationStopsBeforeNativeHandoff(cancelTask: Bool) async throws {
        let scratch = try Scratch(), server = try scratch.folder("server")
        try scratch.file("server/file.txt", "original")
        let root = URL(string: "sftp://share-\(UUID().uuidString).invalid/")!
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let provider = CountingTransferProvider(root: server)
        provider.onDownload = {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        RemoteFS.use(provider, for: root)
        defer { RemoteFS.use(nil, for: root); release.signal() }
        let controller = FileOperationsController()
        let task = Task { try await controller.prepareForSharing([root.appendingPathComponent("file.txt")]) }
        try #require(await offThePool { entered.wait(timeout: .now() + 5) == .success })
        if cancelTask { task.cancel() } else { controller.cancel(try #require(controller.activities.last)) }
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(controller.activities.last?.state == .cancelled)
        #expect(scratch.read("server/file.txt") == "original")
    }

    @Test func remoteSymlinkCannotExposeAnUnrelatedLocalFile() async throws {
        let scratch = try Scratch()
        let server = try scratch.folder("server")
        let secret = try scratch.file("outside.txt", "outside")
        try scratch.file("server/tree/inside.txt", "inside")
        try FileManager.default.createSymbolicLink(at: scratch.path("server/tree/link"), withDestinationURL: secret)
        let root = URL(string: "sftp://share-\(UUID().uuidString).invalid/")!
        RemoteFS.use(CountingTransferProvider(root: server), for: root)
        defer { RemoteFS.use(nil, for: root) }
        let staging = try scratch.folder("staging")
        await #expect(throws: (any Error).self) {
            try await offThePool {
                try SharingPreparation.prepare(
                    [root.appendingPathComponent("tree", isDirectory: true)], control: JobControl(), batchID: UUID(),
                    temporaryDirectory: staging, progress: { _ in }, notice: { _ in })
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        #expect(scratch.read("outside.txt") == "outside")
    }

    @Test func cloudCopyUsesDisplayNameAndNeverBecomesARecoveryDestination() async throws {
        let scratch = try Scratch(), server = try FakeDropboxServer()
        let client = try server.client(directory: scratch.path("Dropbox"))
        let provider = DropboxProvider(client: client)
        let root = DropboxLocation(accountID: client.accountID).url
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        let metadata = try await client.metadata("id:hello")
        let source = DropboxLocation(accountID: client.accountID, itemID: metadata.id).url
        let controller = FileOperationsController()
        let prepared = try await controller.prepareForSharing([source])
        defer { prepared.cleanup() }
        let local = try #require(prepared.urls.first)
        #expect(local.lastPathComponent == metadata.name && local.lastPathComponent != source.lastPathComponent)
        #expect(DropboxContentHash.hash(try Data(contentsOf: local)) == metadata.contentHash)
        #expect(try await client.metadata(metadata.id).id == metadata.id)
        let journal = try provider.transferJournal(source)
        let batch = try #require(controller.activities.last?.id)
        let records = try journal.all().filter { $0.batchID == batch }
        #expect(!records.isEmpty && records.allSatisfy { !$0.topLevel && $0.kind == "copy" && $0.phase == .done })
        #expect(controller.recoveryPlans().allSatisfy { $0.cloudBatchID != batch })
    }

    @Test func eligibilityForAHundredThousandFilesDoesNoIO() {
        let urls = (0..<100_000).map { URL(fileURLWithPath: "/sharing-fixture/\($0).txt") }
        let start = ContinuousClock.now
        #expect(SharingPreparation.supports(urls))
        print("Share eligibility 100k local URLs: \(start.duration(to: .now))")
    }

}
