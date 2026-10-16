import Foundation
import Testing

@testable import PorpoiseCore

struct SyncEngineTests {
    private let date = Date(timeIntervalSince1970: 100)
    private func file(_ path: String = "a", size: Int64 = 1, time: Double = 100, hash: String? = nil) -> SyncEntry {
        .init(path: path, size: size, modified: Date(timeIntervalSince1970: time), hash: hash)
    }
    private func plan(
        _ left: [SyncEntry], _ right: [SyncEntry], mode: SyncMode = .twoWay, previous: SyncState? = nil,
        options: SyncCompareOptions = .init(), overrides: [String: SyncOverride] = [:]
    ) -> SyncPlan {
        SyncPlanner.plan(
            SyncComparator.compare(.init(entries: left), .init(entries: right), options: options),
            mode: mode, previous: previous, overrides: overrides)
    }
    @Test func timestampToleranceAndMethods() {
        let left = SyncSnapshot(entries: [file()])
        #expect(SyncComparator.compare(left, .init(entries: [file(time: 102)])).rows[0].status == .same)
        #expect(SyncComparator.compare(left, .init(entries: [file(time: 103)])).rows[0].status == .changed(.newerRight))
        #expect(SyncComparator.compare(left, .init(entries: [file(time: 103)]), options: .init(method: .sizeOnly)).rows[0].status == .same)
        let l = SyncSnapshot(entries: [file(hash: "one")]), r = SyncSnapshot(entries: [file(hash: "two")])
        #expect(SyncComparator.compare(l, r, options: .init(method: .content)).rows[0].status == .changed(.unknown))
        #expect(SyncComparator.compare(left, left, options: .init(method: .content)).rows[0].status != .same)
    }
    @Test func alignedTreeRollupsAndLazyChildren() {
        let dir = SyncEntry(path: "d", kind: .directory)
        let c = SyncComparator.compare(.init(entries: [dir, file("d/a")]), .init(entries: [dir, file("d/a", size: 2)]))
        #expect(c.children().map(\.path) == ["d"])
        #expect(c.children(of: "d").map(\.path) == ["d/a"])
        #expect(c.rows[0].status == .changed(.unknown))
        #expect(SyncPlanner.plan(c, mode: .backup).steps.map(\.path) == ["d/a"])
        #expect(!SyncPlanner.plan(SyncComparator.compare(.init(entries: [], complete: false), .init(entries: [])), mode: .mirror).conflicts.isEmpty)
    }
    @Test func backupMirrorAndFirstTwoWay() {
        #expect(plan([file()], [file("b")], mode: .backup).steps.map(\.action) == [.copy])
        #expect(plan([file()], [file("b")], mode: .mirror).steps.map(\.action) == [.copy, .trash])
        #expect(plan([file()], [file("b")]).steps.allSatisfy { $0.action == .copy })
        #expect(plan([file()], [file(size: 2)]).conflicts.count == 1)
    }
    @Test func editsAndDeletionsFromPreviousState() {
        let old = SyncState(left: .init(entries: [file()]), right: .init(entries: [file()]))
        #expect(plan([file(size: 2, time: 104)], [file()], previous: old).steps.first?.source == .left)
        #expect(plan([file()], [file(size: 2, time: 104)], previous: old).steps.first?.source == .right)
        #expect(plan([file(size: 2)], [file(size: 3)], previous: old).conflicts.count == 1)
        #expect(plan([], [file()], previous: old).steps.first?.action == .trash)
        #expect(plan([], [file(size: 2)], previous: old).conflicts.count == 1)
        #expect(plan([], [], previous: old).steps.isEmpty)
    }
    @Test func directoryDeleteNeverSweepsEditsOrSkippedChildren() {
        let dir = SyncEntry(path: "d", kind: .directory), child = file("d/a")
        let old = SyncState(left: .init(entries: [dir, child]), right: .init(entries: [dir, child]))
        let edited = plan([], [dir, file("d/a", size: 3)], previous: old)
        #expect(edited.conflicts.count == 1)
        #expect(!edited.steps.contains { $0.path == "d" && $0.action == .trash })
        let skipped = plan([], [dir, child], mode: .mirror, overrides: ["d/a": .skip])
        #expect(skipped.steps.isEmpty)
        #expect(plan([], [dir, child], mode: .mirror).steps.map(\.path) == ["d/a", "d"])
    }
    @Test func caseSensitivityAndCollisions() {
        let left = SyncSnapshot(entries: [file("A"), file("a")])
        #expect(SyncComparator.compare(left, .init(entries: [], caseSensitive: true)).rows.count == 2)
        let collision = SyncComparator.compare(left, .init(entries: [], caseSensitive: false))
        #expect(collision.rows.first?.status == .collision)
        #expect(SyncPlanner.plan(collision, mode: .mirror, overrides: ["A": .keepLeft]).conflicts.count == 1)
        let aligned = SyncComparator.compare(.init(entries: [file("A")]), .init(entries: [file("a")], caseSensitive: false))
        #expect(aligned.rows.count == 1); #expect(aligned.rows.first?.status == .same)
    }
    @Test func linksExclusionsAndUnsafePaths() {
        let a = SyncEntry(path: "link", kind: .symlink, linkTarget: "../a")
        let b = SyncEntry(path: "link", kind: .symlink, linkTarget: "../b")
        #expect(plan([a], [b]).conflicts.count == 1)
        #expect(plan([a], [a]).steps.isEmpty)
        let options = SyncCompareOptions(exclusions: ["*.tmp", "cache/", "**/.git"])
        #expect(
            plan([file("cache/a"), file("a.tmp"), file("d/.git/config"), file("keep")], [], mode: .mirror, options: options).steps.map(\.path) == [
                "keep"
            ])
        #expect(plan([file("../escape")], [], mode: .mirror).conflicts.count == 1)
        #expect(plan([.init(path: "d", kind: .directory)], [file("d")], mode: .mirror).conflicts.count == 1)
    }
    @Test func overridesAndIdempotentReplan() {
        #expect(plan([file()], [file(size: 2)], overrides: ["a": .keepRight]).steps.first?.source == .right)
        #expect(plan([file()], [file()], mode: .mirror).steps.isEmpty)
        #expect(plan([file(), file("b")], [file()], mode: .backup).steps.map(\.path) == ["b"])
    }
    @Test func compareHundredThousandWarm() {
        let entries = (0..<100_000).map { file("file-\($0)") }
        let snapshot = SyncSnapshot(entries: entries)
        _ = SyncComparator.compare(snapshot, snapshot)
        let start = Date()
        let result = SyncComparator.compare(snapshot, snapshot)
        print("SYNC_PERF core 100000 rows: \(Date().timeIntervalSince(start)) seconds")
        #expect(result.rows.count == 100_000)
        #expect(result.rows.allSatisfy { $0.status == .same })
    }
}

extension SyncEngineTests {
    @Test func keepBothPreservesBothVersionsBeforeReplacement() {
        let comparison = SyncComparator.compare(
            .init(entries: [file("a.txt")]),
            .init(entries: [file("a.txt", size: 2), file("a (right).txt")]))
        let result = SyncPlanner.plan(comparison, mode: .twoWay, overrides: ["a.txt": .keepBoth])
        #expect(result.conflicts.isEmpty)
        let replacement = result.steps.first { $0.action == .replace }
        #expect(replacement?.dependsOn.count == 2)
        #expect(result.steps.last?.action == .replace)
        #expect(result.steps.contains { $0.path == "a (right 2).txt" && $0.target == .left })
        #expect(result.steps.contains { $0.path == "a (right 2).txt" && $0.target == .right })
    }
}

extension SyncEngineTests {
    @Test func caseInsensitiveParentSpellingAndPreviousStateAreAligned() {
        let l = SyncSnapshot(entries: [.init(path: "Folder", kind: .directory), file("Folder/new")])
        let r = SyncSnapshot(entries: [.init(path: "folder", kind: .directory)], caseSensitive: false)
        let result = SyncPlanner.plan(SyncComparator.compare(l, r), mode: .backup)
        #expect(result.steps.first?.path == "folder/new")
        #expect(result.steps.first?.sourcePath == "Folder/new")
        let old = SyncState(left: .init(entries: [file("A")]), right: .init(entries: [file("a")], caseSensitive: false))
        let deleted = SyncPlanner.plan(
            SyncComparator.compare(.init(entries: []), .init(entries: [file("A")], caseSensitive: false)), mode: .twoWay, previous: old)
        #expect(deleted.steps.first?.action == .trash)
    }
}
