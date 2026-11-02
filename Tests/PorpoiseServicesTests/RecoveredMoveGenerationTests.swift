import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct RecoveredMoveGenerationTests {
    @Test(arguments: ["before-plan", "after-plan", "missing-identity"])
    func replacementWithIdenticalBytesNeverBecomesDeletionAuthority(_ timing: String) throws {
        let scratch = try Scratch("recovered-move-original-identity")
        let source = try scratch.file("source", "same bytes")
        let target = try scratch.file("target", "same bytes")
        var journal = JobJournal(id: UUID(), kind: .move, sources: [source], destination: scratch.url)
        journal.apply(.placed(index: 0, target: target))
        var plan = try #require(FileOperationsController.plan(journal))
        if timing != "missing-identity" {
            // Keep the old inode alive so the replacement cannot reuse it.
            try FileManager.default.moveItem(at: source, to: scratch.path("previous-original"))
            try scratch.file("source", "same bytes")
            if timing == "before-plan" {
                plan = try #require(FileOperationsController.plan(journal))
                #expect(plan.unfinishedMoves.isEmpty && !plan.notes.isEmpty)
            }
        } else {
            plan.identities[source] = nil
        }
        let out = LocalRecoveryRunner(plan: plan, control: JobControl()).run()
        #expect(scratch.read("source") == "same bytes" && scratch.read("target") == "same bytes")
        #expect(out.removedOriginals.isEmpty)
        if timing != "before-plan" { #expect(!out.errors.isEmpty) }
    }

    @Test(arguments: ["child-edit", "target-edit", "cancel", "late-stop", "unchanged"])
    func recoveredMoveUsesClaimedGenerationChecks(_ change: String) throws {
        let scratch = try Scratch("recovered-move-generation")
        let source = try scratch.folder("source")
        try scratch.file("source/first.txt", "old bytes")
        try scratch.file("source/later.txt", "later bytes")
        let target = scratch.path("destination")
        try FileManager.default.copyItem(at: source, to: target)
        var journal = JobJournal(id: UUID(), kind: .move, sources: [source], destination: scratch.url)
        journal.apply(.placed(index: 0, target: target))
        var plan = RecoveryPlan(id: journal.id, kind: .move, destination: scratch.url)
        plan.unfinishedMoves = [(source, target)]
        plan.identities[source] = try #require(journal.items.first?.fingerprint)
        plan.journal = journal
        let control = JobControl()
        let stages = TransferStageJournal(folder: scratch.path("stages"))
        var runner = LocalRecoveryRunner(plan: plan, control: control)
        runner.stageJournal = stages
        var claimedSource: URL?
        var changed = false
        runner.removalCheckpoint = { checkpoint in
            if case .claimed(let holding, _, _, let verified) = checkpoint {
                claimedSource = holding.appendingPathComponent(source.lastPathComponent)
                if verified && !changed {
                    changed = true
                    if change == "cancel" { control.cancel() }
                    if change == "child-edit" {
                        // Editing the existing child leaves the source directory's own fingerprint unchanged.
                        let file = try FileHandle(forWritingTo: try #require(claimedSource).appendingPathComponent("first.txt"))
                        try file.write(contentsOf: Data("new bytes".utf8)); try file.close()
                    }
                    if change == "target-edit" {
                        let file = try FileHandle(forWritingTo: target.appendingPathComponent("first.txt"))
                        try file.write(contentsOf: Data("new bytes".utf8)); try file.close()
                    }
                }
            }
            if case .deleting = checkpoint, change == "late-stop" { control.cancel() }
        }
        let out = runner.run()
        switch change {
        case "child-edit", "target-edit":
            #expect(out.removedOriginals.isEmpty && !out.errors.isEmpty)
            let held = try #require(claimedSource)
            #expect(
                try String(contentsOf: held.appendingPathComponent("first.txt"), encoding: .utf8)
                    == (change == "child-edit" ? "new bytes" : "old bytes"))
            #expect(out.journal?.items.first?.state == .placed)
            let recovered = stages.recover()
            #expect(!recovered.isEmpty)
            #expect(FileJob.itemExists(at: held.appendingPathComponent("first.txt")))
        case "cancel":
            #expect(out.stopped && out.removedOriginals.isEmpty)
            #expect(scratch.read("source/first.txt") == "old bytes")
            #expect(stages.recover().isEmpty)
        default:
            #expect(out.errors.isEmpty && out.removedOriginals == [source])
            #expect(!FileJob.itemExists(at: source))
            #expect(scratch.read("destination/first.txt") == "old bytes")
            #expect(out.journal?.items.first?.state == .done)
            #expect(out.stopped == (change == "late-stop"))
            #expect(stages.recover().isEmpty)
        }
    }
}
