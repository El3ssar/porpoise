import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseHelperKit
@testable import PorpoiseServices

/// Runs the deployed descriptor operations in-process on scratch files as the current user, never through XPC/root.
struct AdministratorTransferTests {
    private func execute(_ commands: [[String]], boundary: @escaping (HelperBoundary) -> Void = { _ in }) -> FileOperationsController.ElevatedOutcome
    {
        for command in commands {
            if let message = HelperRequests.refusal(command) { return .failed(message) }
            var helper = HelperFileOperations(boundary: boundary)
            if let message = helper.run(command) { return .failed(message) }
        }
        return .done
    }

    private func command(_ kind: FileOperationKind, _ source: URL, _ target: URL) -> [String] {
        kind == .copy ? ["/bin/cp", "-pR", "--", source.path, target.path] : ["/bin/mv", "--", source.path, target.path]
    }

    @Test(arguments: [FileOperationKind.copy, .move])
    func freshTargetsArePublishedAndOnlyActualPlacementsAreReceipts(_ kind: FileOperationKind) throws {
        let scratch = try Scratch(), source = try scratch.file("source", "new bytes"), target = scratch.path("target")
        let batch = AdministratorTransferBatch(
            kind: kind, commands: [command(kind, source, target)], elevate: { commands, _, _ in execute(commands) })
        #expect(batch.run(viaHelper: true) == .done)
        #expect(batch.completion.targets == [target] && batch.completion.errors.isEmpty)
        #expect(scratch.read("target") == "new bytes")
        #expect(FileManager.default.fileExists(atPath: source.path) == (kind == .copy))
        #expect(batch.completion.moves.count == (kind == .move ? 1 : 0))
        #expect(!scratch.listing().contains { $0.hasPrefix(".porpoise-") })
    }

    @Test func freshFolderCopiesKeepTheTree() throws {
        let scratch = try Scratch(), source = try scratch.folder("source"), target = scratch.path("target")
        try scratch.file("source/nested/item", "tree")
        let batch = AdministratorTransferBatch(
            kind: .copy, commands: [command(.copy, source, target)], elevate: { commands, _, _ in execute(commands) })
        #expect(batch.run(viaHelper: true) == .done)
        #expect(scratch.read("target/nested/item") == "tree" && scratch.read("source/nested/item") == "tree")
        #expect(batch.completion.targets == [target])
    }

    @Test(arguments: [FileOperationKind.copy, .move])
    func anOccupiedTargetIsRefusedBeforeAnyBackendRequest(_ kind: FileOperationKind) throws {
        let scratch = try Scratch(), source = try scratch.file("source", "source"), target = try scratch.file("target", "existing")
        var calls = 0
        let batch = AdministratorTransferBatch(
            kind: kind, commands: [command(kind, source, target)],
            elevate: { _, _, _ in
                calls += 1; return .done
            })
        guard case .failed(let message) = batch.run(viaHelper: true) else { Issue.record("Expected a refusal"); return }
        #expect(message.contains("the existing item was left unchanged"))
        #expect(calls == 0 && batch.completion.targets.isEmpty && batch.completion.moves.isEmpty)
        #expect(scratch.read("source") == "source" && scratch.read("target") == "existing")
    }

    @Test func danglingLinksAlsoReserveTheTarget() throws {
        let scratch = try Scratch(), source = try scratch.file("source", "source"), target = try scratch.symlink("target", to: "absent")
        let plan = FileOperationsController.administratorCommands(.copy, [source], targets: [source: target], to: scratch.url)
        #expect(plan.commands.isEmpty && plan.skipped.first?.contains("the existing item was left unchanged") == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == "absent")
    }

    @Test func aTargetArrivingDuringTheCopyKeepsBothOriginalAndStagedBytes() throws {
        let scratch = try Scratch(), source = try scratch.file("source", "copy bytes"), target = scratch.path("target")
        var calls = 0
        let batch = AdministratorTransferBatch(
            kind: .copy, commands: [command(.copy, source, target)],
            elevate: { commands, _, _ in
                calls += 1
                let result = execute(commands)
                if commands.first?.first == "/bin/cp" {
                    do { try Data("arrived".utf8).write(to: target) } catch { Issue.record(error) }
                }
                return result
            })
        guard case .failed(let message) = batch.run(viaHelper: true) else { Issue.record("Expected a late-target refusal"); return }
        #expect(message.contains("the existing item was left unchanged") && message.contains("recovery"))
        #expect(calls == 1 && batch.completion.targets.isEmpty)
        #expect(scratch.read("target") == "arrived" && scratch.read("source") == "copy bytes")
        let retained = try #require(scratch.listing().first { $0.hasPrefix(".porpoise-copy-") })
        #expect(scratch.read(retained) == "copy bytes")
    }

    @Test(arguments: [FileOperationKind.copy, .move])
    func aTargetArrivingAtExclusivePublicationIsNeverReplaced(_ kind: FileOperationKind) throws {
        let scratch = try Scratch(), source = try scratch.file("source", "source"), target = scratch.path("target")
        var injected = false
        let batch = AdministratorTransferBatch(
            kind: kind, commands: [command(kind, source, target)],
            elevate: { commands, _, _ in
                execute(commands) { point in
                    if !injected, point.phase == .beforePublish, point.path == target.path {
                        injected = true
                        do { try Data("raced target".utf8).write(to: target) } catch { Issue.record(error) }
                    }
                }
            })
        guard case .failed = batch.run(viaHelper: true) else { Issue.record("Expected exclusive publication to fail"); return }
        #expect(injected && batch.completion.targets.isEmpty && batch.completion.moves.isEmpty)
        #expect(scratch.read("target") == "raced target" && scratch.read("source") == "source")
        if kind == .copy {
            let retained = try #require(scratch.listing().first { $0.hasPrefix(".porpoise-copy-") })
            #expect(scratch.read(retained) == "source")
        }
    }

    @Test(arguments: [FileOperationKind.copy, .move])
    func aSuccessfulNoReplaceNoOpDoesNotBecomeASuccessReceipt(_ kind: FileOperationKind) throws {
        let scratch = try Scratch(), source = try scratch.file("source", "source"), target = scratch.path("target")
        let batch = AdministratorTransferBatch(
            kind: kind, commands: [command(kind, source, target)],
            elevate: { commands, _, _ in
                if commands.first?.first == "/bin/mv" {
                    do { try Data("new target".utf8).write(to: target) } catch { Issue.record(error) }
                }
                return execute(commands)
            })
        guard case .failed(let message) = batch.run(viaHelper: true) else { Issue.record("Expected a no-op refusal"); return }
        #expect(message.contains("the existing item was left unchanged"))
        #expect(batch.completion.targets.isEmpty && batch.completion.moves.isEmpty)
        #expect(scratch.read("target") == "new target" && scratch.read("source") == "source")
    }

    @Test func aNewGenerationAtTheMovedSourceIsNeverReportedAsMoved() throws {
        let scratch = try Scratch(), source = try scratch.file("source", "original"), target = scratch.path("target")
        let batch = AdministratorTransferBatch(
            kind: .move, commands: [command(.move, source, target)],
            elevate: { commands, _, _ in
                let result = execute(commands)
                do { try Data("new generation".utf8).write(to: source) } catch { Issue.record(error) }
                return result
            })
        guard case .failed(let message) = batch.run(viaHelper: true) else { Issue.record("Expected an unconfirmed placement"); return }
        #expect(message.contains("could not be confirmed") && !message.contains("the existing item was left unchanged"))
        #expect(batch.completion.targets.isEmpty && batch.completion.moves.isEmpty)
        #expect(scratch.read("source") == "new generation" && scratch.read("target") == "original")
    }

    @Test func partialBatchesKeepOnlyTheSuccessfulReceipts() throws {
        let scratch = try Scratch(), first = try scratch.file("first", "first"), second = try scratch.file("second", "second")
        let target = scratch.path("target"), occupied = try scratch.file("occupied", "unchanged")
        let batch = AdministratorTransferBatch(
            kind: .move, commands: [command(.move, first, target), command(.move, second, occupied)],
            elevate: { commands, _, _ in execute(commands) })
        guard case .failed = batch.run(viaHelper: true) else { Issue.record("Expected partial failure"); return }
        #expect(batch.completion.targets == [target] && batch.completion.moves.count == 1)
        #expect(batch.completion.moves.first?.from == first && batch.completion.moves.first?.to == target)
        #expect(scratch.read("occupied") == "unchanged" && scratch.read("second") == "second")
    }

    @Test func theShellFallbackFailsClosedWithoutExecutingAnyCommand() throws {
        let scratch = try Scratch(), source = try scratch.file("source", "source"), target = scratch.path("target")
        var calls = 0
        let batch = AdministratorTransferBatch(
            kind: .copy, commands: [command(.copy, source, target)],
            elevate: { _, _, _ in
                calls += 1; return .done
            })
        guard case .failed = batch.run(viaHelper: false) else { Issue.record("Expected unsupported safe-publication refusal"); return }
        #expect(calls == 0 && batch.completion.targets.isEmpty && scratch.read("source") == "source" && scratch.read("target") == nil)
    }

    @Test func cancellingPublicationRetainsAndNamesTheStagedCopy() throws {
        let scratch = try Scratch(), source = try scratch.file("source", "copy"), target = scratch.path("target")
        let batch = AdministratorTransferBatch(
            kind: .copy, commands: [command(.copy, source, target)],
            elevate: { commands, _, _ in
                commands.first?.first == "/bin/mv" ? .cancelled : execute(commands)
            })
        guard case .failed(let message) = batch.run(viaHelper: true) else {
            Issue.record("Recovery information must not disappear on cancellation"); return
        }
        #expect(message.contains("recovery") && batch.completion.targets.isEmpty && scratch.read("target") == nil)
        let retained = try #require(scratch.listing().first { $0.hasPrefix(".porpoise-copy-") })
        #expect(scratch.read(retained) == "copy" && scratch.read("source") == "copy")
    }
}
