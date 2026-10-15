import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings, .serialized)
struct TransferExperienceTests {
    @Test(arguments: [TransferConflictRule.newer, .different, .larger])
    func conditionalRulesApplyIndependentlyToEveryRemainingConflict(_ rule: TransferConflictRule) async throws {
        let s = try Scratch("conditional-conflicts")
        let newer = try s.file("src/newer", "new and larger")
        let older = try s.file("src/older", "old")
        let equal = try s.file("src/equal", "same")
        let targets = try ["newer", "older", "equal"].map {
            try s.file("dst/\($0)", $0 == "older" ? "destination larger" : $0 == "equal" ? "same" : "old")
        }
        let fm = FileManager.default
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        for target in targets { try fm.setAttributes([.modificationDate: epoch], ofItemAtPath: target.path) }
        for (file, offset) in [(newer, 100.0), (older, -100.0), (equal, 0.0)] {
            try fm.setAttributes([.modificationDate: epoch.addingTimeInterval(offset)], ofItemAtPath: file.path)
        }
        let ui = ScriptedUI(conflicts: [ConflictAnswer(rule.resolution!, applyToAll: true)])
        let c = makeController(ui)
        _ = await c.perform(.copy, [newer, older, equal], to: s.path("dst"))
        #expect(ui.conflicts.count == 1)
        #expect(ui.conflicts.first?.remainingConflicts == 3)
        #expect(s.read("dst/newer") == "new and larger")
        #expect(s.read("dst/equal") == "same")
        #expect(s.read("dst/older") == (rule == .different ? "old" : "destination larger"))
    }

    @Test func upfrontKeepBothNeverAsksAndNeverReplaces() async throws {
        let s = try Scratch("upfront-conflict")
        let a = try s.file("src/a.txt", "incoming")
        try s.file("dst/a.txt", "existing")
        Settings.shared.transferConflictRule = .keepBoth
        let ui = ScriptedUI()
        _ = await makeController(ui).perform(.copy, [a], to: s.path("dst"))
        #expect(ui.conflicts.isEmpty)
        #expect(s.read("dst/a.txt") == "existing")
        #expect(s.read("dst/a (1).txt") == "incoming")
    }

    @Test func differentUsesTheSyncToleranceAndReportsIdenticalSkips() async throws {
        let s = try Scratch("identical-summary")
        let src = try s.file("src/report", "same")
        let dst = try s.file("dst/report", "same")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: src.path)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(1)], ofItemAtPath: dst.path)
        let before = JobJournal.Fingerprint(dst)
        Settings.shared.transferConflictRule = .different
        let c = makeController(ScriptedUI())
        _ = await c.perform(.copy, [src], to: s.path("dst"))
        #expect(JobJournal.Fingerprint(dst) == before)
        #expect(c.activities.last?.progress?.skippedIdenticalItems == 1)
        #expect(c.activities.last?.statusText.contains("Skipped 1 identical") == true)
    }

    @Test func contentModeReplacesEqualMetadataWhenBytesDiffer() async throws {
        let s = try Scratch("content-compare")
        let src = try s.file("src/report", "new!")
        let dst = try s.file("dst/report", "old!")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for file in [src, dst] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
        Settings.shared.transferConflictRule = .different
        Settings.shared.transferCompareMethod = .content
        let c = makeController(ScriptedUI())
        _ = await c.perform(.copy, [src], to: s.path("dst"))
        #expect(s.read("dst/report") == "new!")
        #expect(c.activities.last?.progress?.replacedItems == 1)
    }

    @Test func identicalFolderMetadataDoesNotSkipChangedChildren() async throws {
        let s = try Scratch("different-folder")
        try s.file("src/folder/changed", "incoming-longer")
        try s.file("dst/folder/changed", "old")
        let same = try s.file("src/folder/same", "same")
        let existing = try s.file("dst/folder/same", "same")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for file in [same, existing] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
        let inode = JobJournal.Fingerprint(existing)?.inode
        Settings.shared.transferConflictRule = .different
        let c = makeController(ScriptedUI())
        _ = await c.perform(.copy, [s.path("src/folder")], to: s.path("dst"))
        #expect(s.read("dst/folder/changed") == "incoming-longer")
        #expect(JobJournal.Fingerprint(existing)?.inode == inode)
        #expect(c.activities.last?.progress?.skippedIdenticalItems == 1)
    }

    @Test func preparationCountsTheTreeWithoutFollowingLinks() throws {
        let s = try Scratch("transfer-inventory")
        try s.file("src/folder/one", "one")
        try s.file("src/folder/sub/two", "two")
        try s.symlink("src/folder/link", to: "sub")
        let destination = try s.folder("dst")
        let job = FileJob(kind: .copy, sources: [s.path("src/folder")], destinationFolder: destination)
        var samples: [JobProgress] = []
        job.onProgress = { samples.append($0) }
        _ = try job.run()
        #expect(samples.first?.phase == .preparing)
        let transfer = try #require(samples.first { $0.phase == .transferring })
        #expect(transfer.totalFiles == 3 && transfer.totalFolders == 2 && transfer.totalBytes == 6)
        #expect(samples.last?.doneFiles == 3)
        #expect(samples.last?.doneItems == 1)
        #expect(s.read("dst/folder/sub/two") == "two")
    }
}
