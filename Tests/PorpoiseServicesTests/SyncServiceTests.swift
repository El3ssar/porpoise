import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct SyncServiceTests {
    @Test func localScanExecuteRerunAndLinks() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/d/a", "hello")
        try scratch.symlink("left/link", to: "d")
        try scratch.symlink("left/broken", to: "missing")
        let l = try SyncScanner.scan(left), r = try SyncScanner.scan(right)
        #expect(l.entries.count == 4)
        #expect(!l.entries.contains { $0.path.hasPrefix("link/") })
        let plan = SyncPlanner.plan(SyncComparator.compare(l, r), mode: .backup)
        try SyncExecutor.execute(plan, leftRoot: left, rightRoot: right)
        #expect(scratch.read("right/d/a") == "hello")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scratch.path("right/link").path) == "d")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scratch.path("right/broken").path) == "missing")
        let after = SyncComparator.compare(try SyncScanner.scan(left), try SyncScanner.scan(right))
        #expect(SyncPlanner.plan(after, mode: .backup).steps.isEmpty)
        try scratch.file("left/d/a", "replacement")
        try SyncExecutor.execute(
            SyncPlanner.plan(SyncComparator.compare(try SyncScanner.scan(left), try SyncScanner.scan(right)), mode: .backup),
            leftRoot: left, rightRoot: right)
        #expect(scratch.read("right/d/a") == "replacement")
    }
    @Test func exclusionsLazyContentAndUnreadableRoot() throws {
        let scratch = try Scratch(); try scratch.file("root/d/a", "hello"); try scratch.file("root/cache/no", "no")
        let root = scratch.path("root")
        let scan = try SyncScanner.scan(root, options: .init(method: .content, exclusions: ["cache"]))
        #expect(scan.entries.count == 2)
        #expect(scan.entries.first { $0.path == "d/a" }?.hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        let lazy = try SyncScanner.scan(root, maxDepth: 1)
        #expect(!lazy.complete); #expect(lazy.entries.count == 2)
        #expect(throws: (any Error).self) { try SyncScanner.scan(scratch.path("missing")) }
        #expect(throws: (any Error).self) { try SyncScanner.scan(URL(string: "https://example.test/")!) }
        #expect(throws: (any Error).self) { try SyncScanner.scan(scratch.path("root/d/a")) }
    }
    @Test func stalePreviewTraversalAndSymlinkAncestorsRefused() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/a", "one")
        let plan = SyncPlanner.plan(SyncComparator.compare(try SyncScanner.scan(left), try SyncScanner.scan(right)), mode: .backup)
        try scratch.file("left/a", "different")
        #expect(throws: (any Error).self) { try SyncExecutor.execute(plan, leftRoot: left, rightRoot: right) }
        #expect(!FileManager.default.fileExists(atPath: scratch.path("right/a").path))
        #expect(throws: (any Error).self) {
            try SyncExecutor.execute(SyncPlan(steps: []), leftRoot: URL(fileURLWithPath: "/"), rightRoot: left)
        }
        try scratch.symlink("right/redirect", to: left.path)
        #expect(throws: (any Error).self) { try SyncExecutor.resolve("redirect/a", root: right) }
        #expect(throws: (any Error).self) { try SyncExecutor.resolve("../escape", root: right) }
        #expect(throws: (any Error).self) {
            try SyncExecutor.execute(SyncPlan(steps: []), leftRoot: left, rightRoot: left.appendingPathComponent("child"))
        }
    }
    @Test func stateRoundTripAndWrongPairOrVersionRejected() async throws {
        let scratch = try Scratch(), store = SyncStateStore(folder: scratch.path("states")), id = UUID()
        let left = scratch.path("left"), right = scratch.path("right")
        #expect(try await store.load(pairID: id, leftRoot: left, rightRoot: right) == nil)
        let state = SyncState(left: .init(entries: [.init(path: "a", size: 3, hash: "hash", identity: "id")]), right: .init(entries: []))
        try await store.save(state, pairID: id, leftRoot: left, rightRoot: right)
        #expect(try await store.load(pairID: id, leftRoot: left, rightRoot: right)?.left == state.left)
        do { _ = try await store.load(pairID: id, leftRoot: right, rightRoot: left); Issue.record("Wrong pair accepted") } catch {}
        var invalid = state; invalid.version = 42
        do { try await store.save(invalid, pairID: id, leftRoot: left, rightRoot: right); Issue.record("Wrong version accepted") } catch {}
    }
    @Test func watcherDebouncesAndPauseResumeRequestsScan() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let counter = Counter()
        let watcher = SyncWatcher(roots: [], debounce: 0.03, pollInterval: 100) { counter.increment() }
        for _ in 0..<20 { watcher.requestScan() }
        #expect(await eventually(3) { counter.count == 1 })
        watcher.setPaused(true); watcher.requestScan()
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 1)
        watcher.setPaused(false)
        #expect(await eventually(3) { counter.count == 2 })
        watcher.stop(); watcher.requestScan()
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 2)
    }
    @Test func actualFSEventRequestsScan() async throws {
        let scratch = try Scratch()
        let changed = AsyncStream<Void>.makeStream()
        let watcher = SyncWatcher(roots: [scratch.url], debounce: 0.03, pollInterval: 100) { changed.continuation.yield(()) }
        defer { withExtendedLifetime(watcher) {}; changed.continuation.finish() }
        try await Task.sleep(for: .milliseconds(200))
        try scratch.file("change", "event")
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in changed.stream { return true }; return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5)); return false
            }
            let result = await group.next() ?? false; group.cancelAll(); return result
        }
        #expect(received)
    }
}

extension SyncServiceTests {
    @Test func repeatingRunningStepsVerifiesTheirPostcondition() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/d/a", "hello")
        let plan = SyncPlanner.plan(try SyncScanner.compare(left, right).comparison, mode: .backup)
        for step in plan.steps {
            try SyncExecutor.execute(step, leftRoot: left, rightRoot: right)
            // The process could die here, before the jobs adapter saves its completion checkpoint.
            try SyncExecutor.execute(step, leftRoot: left, rightRoot: right)
        }
        #expect(scratch.read("right/d/a") == "hello")
    }
    @Test func keepBothSurvivesPartialRunAndReplanWithoutExtraVersions() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/a", "left bytes"); try scratch.file("right/a", "right bytes")
        let options = SyncCompareOptions(method: .content)
        let plan = SyncPlanner.plan(try SyncScanner.compare(left, right, options: options).comparison, mode: .twoWay, overrides: ["a": .keepBoth])
        try SyncExecutor.execute(plan.steps[0], leftRoot: left, rightRoot: right)
        let replan = SyncPlanner.plan(try SyncScanner.compare(left, right, options: options).comparison, mode: .twoWay, overrides: ["a": .keepBoth])
        try SyncExecutor.execute(replan, leftRoot: left, rightRoot: right)
        #expect(scratch.read("left/a") == "left bytes"); #expect(scratch.read("right/a") == "left bytes")
        #expect(scratch.read("left/a (right)") == "right bytes"); #expect(scratch.read("right/a (right)") == "right bytes")
        #expect(scratch.listing("left").count == 2); #expect(scratch.listing("right").count == 2)
        #expect(try SyncScanner.compare(left, right, options: options).comparison.rows.allSatisfy { $0.status == .same })
    }
    @Test func physicalCaseSensitiveVolumeKeepsCaseDistinct() throws {
        let scratch = try Scratch()
        let image = scratch.path("case.dmg"), mount = try scratch.folder("mount")
        func run(_ arguments: [String]) throws {
            let result = try Shell.run("/usr/bin/hdiutil", arguments, timeout: 60)
            guard result.status == 0 else { throw SyncEngineError.unsupported(result.err) }
        }
        try run(["create", "-quiet", "-size", "20m", "-fs", "Case-sensitive APFS", "-volname", "SyncCase", image.path])
        try run(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? run(["detach", "-quiet", "-force", mount.path]) }
        try Data("A".utf8).write(to: mount.appendingPathComponent("A"))
        try Data("a".utf8).write(to: mount.appendingPathComponent("a"))
        let scan = try SyncScanner.scan(mount)
        #expect(scan.caseSensitive)
        #expect(Set(scan.entries.filter { ["A", "a"].contains($0.path) }.map(\.path)) == ["A", "a"])
    }
}

extension SyncServiceTests {
    @Test func replacedRootIsNeverInterpretedAsDeletedContents() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/a", "keep"); try scratch.file("right/a", "keep")
        let before = try SyncScanner.compare(left, right)
        let previous = SyncState(left: before.left, right: before.right)
        try FileManager.default.moveItem(at: left, to: scratch.path("detached"))
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false)
        let missingVolume = try SyncScanner.compare(left, right)
        #expect(SyncPlanner.plan(missingVolume.comparison, mode: .twoWay, previous: previous).conflicts.count == 1)
        // Preview an ordinary Mirror deletion, then swap the source root before execution.
        let plan = SyncPlanner.plan(missingVolume.comparison, mode: .mirror)
        try FileManager.default.moveItem(at: left, to: scratch.path("detached2"))
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try SyncExecutor.execute(plan, leftRoot: left, rightRoot: right) }
        #expect(scratch.read("right/a") == "keep")
    }
    @Test func executorUsesConfiguredTimestampTolerance() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/a", "new"); try scratch.file("right/a", "old")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: scratch.path("left/a").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 101)], ofItemAtPath: scratch.path("right/a").path)
        let plan = SyncPlanner.plan(
            try SyncScanner.compare(left, right, options: .init(timestampTolerance: 0)).comparison, mode: .backup, overrides: ["a": .keepLeft])
        #expect(plan.steps.count == 1)
        try SyncExecutor.execute(plan, leftRoot: left, rightRoot: right)
        #expect(scratch.read("right/a") == "new")
    }
}

extension SyncServiceTests {
    @Test func caseOnlyRenamesUpdateContentsThenParentsAndReplaySafely() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/Folder/Readme.md", "new contents")
        try scratch.file("right/folder/README.md", "old")
        let options = SyncCompareOptions(method: .content)
        var l = try SyncScanner.scan(left, options: options), r = try SyncScanner.scan(right, options: options)
        l.caseSensitive = false; r.caseSensitive = false
        let plan = SyncPlanner.plan(SyncComparator.compare(l, r, options: options), mode: .mirror)
        #expect(plan.steps.last?.renameTo == "Folder")
        try SyncExecutor.execute(plan, leftRoot: left, rightRoot: right)
        #expect(scratch.read("right/Folder/Readme.md") == "new contents")
        #expect(try FileManager.default.contentsOfDirectory(atPath: right.path) == ["Folder"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: right.appendingPathComponent("Folder").path) == ["Readme.md"])
        let fresh = try SyncScanner.compare(left, right, options: options)
        #expect(SyncPlanner.plan(fresh.comparison, mode: .mirror).steps.isEmpty)
        // The directory step may be replayed after publishing but before its journal checkpoint.
        try SyncExecutor.execute(try #require(plan.steps.last), leftRoot: left, rightRoot: right)
    }
    @Test func backupDefaultNeverExecutesNewerDestinationReplacement() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        try scratch.file("left/a", "source"); try scratch.file("right/a", "newer work")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: left.appendingPathComponent("a").path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: right.appendingPathComponent("a").path)
        let preview = try SyncPreparation.preview(SavedSync(left: left, right: right, mode: .backup))
        #expect(preview.skippedConflicts == 1)
        try SyncExecutor.execute(preview.executable, leftRoot: left, rightRoot: right)
        #expect(scratch.read("right/a") == "newer work")
        let approved = SyncPreparation.replan(preview, pair: preview.pair, previous: nil, overrides: ["a": .keepLeft])
        try SyncExecutor.execute(approved.executable, leftRoot: left, rightRoot: right)
        #expect(scratch.read("right/a") == "source")
    }
}

extension SyncServiceTests {
    @Test func directoryRenameRefusesAReplacedTargetAndUnsafeSpelling() throws {
        let scratch = try Scratch(), left = try scratch.folder("left"), right = try scratch.folder("right")
        _ = try scratch.folder("left/Folder"); _ = try scratch.folder("right/folder")
        var l = try SyncScanner.scan(left), r = try SyncScanner.scan(right)
        l.caseSensitive = false; r.caseSensitive = false
        let plan = SyncPlanner.plan(SyncComparator.compare(l, r), mode: .backup)
        var unsafe = try #require(plan.steps.first)
        unsafe.renameTo = "../escape"
        #expect(throws: (any Error).self) { try SyncExecutor.execute(unsafe, leftRoot: left, rightRoot: right) }
        try FileManager.default.moveItem(at: right.appendingPathComponent("folder"), to: right.appendingPathComponent("detached"))
        _ = try scratch.folder("right/folder")
        #expect(throws: (any Error).self) { try SyncExecutor.execute(plan, leftRoot: left, rightRoot: right) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: right.path).contains("folder"))
    }
}
