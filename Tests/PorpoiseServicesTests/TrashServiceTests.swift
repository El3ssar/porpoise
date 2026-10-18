import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.isolatedSettings) struct TrashServiceTests {
    @Test func originsAreSharedImmediatelyAndFlushedOncePerBatch() throws {
        let store = TrashCountingDefaults()
        Settings.store = store
        let service = TrashService(), other = TrashService()
        service.record(
            (0..<100).map { i in
                (original: URL(fileURLWithPath: "/original/\(i)"), inTrash: URL(fileURLWithPath: "/trash/\(i)"))
            })
        #expect(other.originalLocation(of: URL(fileURLWithPath: "/trash/99"))?.path == "/original/99")
        service.flush()
        #expect(store.writes == 1)
        #expect((store.dictionary(forKey: "trashOrigins") as? [String: String])?.count == 100)
        other.flush()
        #expect(store.writes == 1)
        Settings.store = MemoryDefaults()
        #expect(service.originalLocation(of: URL(fileURLWithPath: "/trash/99")) == nil)
    }

    @Test func anOffMainPruneKeepsExistingTrashEntries() async throws {
        let s = try Scratch()
        let existing = try s.file("trash/exists"), missing = s.path("trash/gone")
        let service = TrashService()
        service.record([(s.path("original/exists"), existing), (s.path("original/gone"), missing)])
        service.record([])
        #expect(await eventually(5) { service.originalLocation(of: missing) == nil })
        #expect(service.originalLocation(of: existing) == s.path("original/exists"))
        service.flush()
        #expect((Settings.store.dictionary(forKey: "trashOrigins") as? [String: String])?.count == 1)
    }

    @Test func unlockingADeleteTreeDoesNotChangeAnExternalSymlinkTarget() throws {
        let s = try Scratch()
        let external = try s.file("external", "untouched"), inside = try s.file("tree/sub/file", "owned")
        try s.symlink("tree/link", to: external.path)
        chmod(external.path, 0o400); chmod(inside.path, 0o400)
        chflags(inside.path, UInt32(UF_IMMUTABLE))
        defer { chflags(inside.path, 0); chmod(external.path, 0o600) }
        FileOperationsController.unlockForRemoval(s.path("tree"), recursively: true)
        var externalInfo = stat(), insideInfo = stat()
        #expect(lstat(external.path, &externalInfo) == 0 && externalInfo.st_mode & mode_t(S_IWUSR) == 0)
        #expect(lstat(inside.path, &insideInfo) == 0 && insideInfo.st_mode & mode_t(S_IWUSR) != 0)
        #expect(insideInfo.st_flags & UInt32(UF_IMMUTABLE) == 0)
    }

    @Test func allRoutesRecordOriginsAndAFailedBatchRollsBack() throws {
        let scratch = try Scratch()
        let a = try scratch.file("source/a", "a"), b = try scratch.file("source/b", "b")
        let trash = try scratch.folder("trash")
        let service = TrashService { url in
            if url == b { throw CocoaError(.fileWriteNoPermission) }
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        #expect(throws: CocoaError.self) { try service.trash([a, b]) }
        #expect(scratch.read("source/a") == "a" && scratch.read("source/b") == "b")
        #expect(service.originalLocation(of: trash.appendingPathComponent("a")) == nil)
        let result = try service.trash([a])
        #expect(result.count == 1 && service.originalLocation(of: result[0].inTrash) == a)
    }

    @Test func undoAndReplacementUseTheSameOriginLedgerAndRollbackPolicy() throws {
        let scratch = try Scratch(), trash = try scratch.folder("trash")
        let service = TrashService { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        let created = try scratch.file("created", "copy")
        let inverse = try FileActions.undo(.created([created]), trash: service.trash)
        guard case .trashed(let pairs) = inverse else { Issue.record("Expected Trash inverse"); return }
        #expect(service.originalLocation(of: pairs[0].inTrash) == created)
        let staged = try scratch.file(".stage", "previous"), original = scratch.path("report.txt")
        try service.disposeReplacement(staged, original: original)
        service.flush()
        let origins = Settings.store.dictionary(forKey: "trashOrigins") as? [String: String] ?? [:]
        #expect(origins.values.contains(original.path))
        #expect(!FileJob.itemExists(at: staged))
        let failing = TrashService { _ in throw CocoaError(.featureUnsupported) }
        let stage2 = try scratch.file(".stage2", "safe")
        #expect(throws: CocoaError.self) { try failing.disposeReplacement(stage2, original: original) }
        #expect(scratch.read(".stage2") == "safe")
        #expect(scratch.listing().allSatisfy { !$0.hasPrefix(".porpoise-replaced-") })
    }

    @Test func unsupportedTrashStillOffersTheLocalJobFallback() throws {
        let scratch = try Scratch(), source = try scratch.file("file", "safe")
        let job = FileJob(kind: .trash, sources: [source])
        let service = TrashService { _ in throw CocoaError(.featureUnsupported) }
        job.trashItem = { try service.trash([$0]).first?.inTrash }
        _ = try job.run()
        #expect(job.untrashable == [source] && job.errors.isEmpty)
        #expect(scratch.read("file") == "safe")
    }
}

private final class TrashCountingDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var count = 0
    var writes: Int { lock.withLock { count } }
    init() { super.init(suiteName: nil)! }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) {
        lock.withLock {
            count += 1; values[key] = value
        }
    }
}
