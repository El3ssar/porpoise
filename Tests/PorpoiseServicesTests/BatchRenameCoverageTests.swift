import CoreGraphics
import Foundation
import ImageIO
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing
import UniformTypeIdentifiers

@testable import PorpoiseCore
@testable import PorpoiseServices

/// Batch rename's error paths: what a snapshot refuses, plans that don't match it, sources that change during the
/// batch, and rows the planner can't name.
@Suite(.isolatedSettings) struct BatchRenameCoverageTests {
    private func rename(_ to: String) -> BatchRenamePreset { BatchRenamePreset(name: "", rules: [.template(to)]) }

    @Test func snapshotRefusesRemoteAndMissingItems() throws {
        let scratch = try Scratch()
        let file = try scratch.file("a", "data")
        do {
            _ = try BatchRenameService.snapshot([file, URL(string: "sftp://example.invalid/a")!])
            Issue.record("A remote item was accepted")
        } catch let error as BatchRenameError {
            #expect(error.localizedDescription.contains("local files"))
        }
        #expect(throws: POSIXError.self) { try BatchRenameService.snapshot([scratch.path("missing")]) }
        #expect(throws: POSIXError.self) { try BatchRenameService.snapshot([scratch.path("no-folder/child")]) }
        #expect(scratch.listing() == ["a"])
    }

    @Test func snapshotResolvesParentsAndListsEveryFolderOnce() throws {
        let scratch = try Scratch()
        let one = try scratch.file("one/a.txt"), two = try scratch.file("two/b.txt")
        try scratch.file("one/.hidden")
        try scratch.folder("one/sub")
        try scratch.symlink("alias", to: scratch.path("one").path)
        let snapshot = try BatchRenameService.snapshot([one, scratch.path("alias/sub"), two], mediaMetadata: false)
        let parent = one.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        #expect(
            snapshot.entries.map(\.url) == [
                parent.appendingPathComponent("a.txt"), parent.appendingPathComponent("sub"), two.resolvingSymlinksInPath(),
            ])
        #expect(snapshot.entries.map(\.isDirectory) == [false, true, false])
        #expect(snapshot.entries[0].modified != nil && snapshot.entries[0].created != nil)
        #expect(snapshot.existing.count == 2 && Set(snapshot.existing[parent.path] ?? []) == [".hidden", "a.txt", "sub"])
        #expect(snapshot.caseSensitive.count == 2)
        // Renaming the folder through the alias renames the real folder.
        let plan = BatchRenameService.preview(snapshot, preset: BatchRenamePreset(name: "", rules: [.changeCase(.upper)]))
        #expect(plan.changes.count == 3 && plan.canApply)
        let result = try BatchRenameService.execute(plan, snapshot: snapshot)
        #expect(result.urls.map(\.lastPathComponent) == ["A.txt", "SUB", "B.txt"])
        #expect(scratch.listing("one") == [".hidden", "A.txt", "SUB"] && scratch.listing("two") == ["B.txt"])
        _ = try FileActions.undo(try #require(result.undo))
        #expect(Set(scratch.listing("one")) == [".hidden", "a.txt", "sub"] && scratch.listing("two") == ["b.txt"])
    }

    @Test func audioAndBrokenImageFilesStillSnapshot() throws {
        let scratch = try Scratch()
        let song = try scratch.file("song.mp3", "not really audio")
        let broken = try scratch.file("broken.png", "not really an image")
        let snapshot = try BatchRenameService.snapshot([song, broken])
        #expect(snapshot.entries[1].metadata.isEmpty && snapshot.entries[1].exifDate == nil)
        #expect(snapshot.entries[0].metadata["width"] == nil)
        // Missing metadata blocks only the rows that need it.
        let plan = BatchRenameService.preview(snapshot, preset: rename("{width}"))
        #expect(!plan.canApply && plan.rows.allSatisfy { $0.problem?.contains("width") == true })
    }

    @Test func exifDateWithOffsetIsAbsolute() throws {
        let scratch = try Scratch()
        let url = scratch.path("photo.jpg")
        let context = try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2024:02:03 12:34:56", kCGImagePropertyExifOffsetTimeOriginal: "+02:00"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let snapshot = try BatchRenameService.snapshot([url])
        #expect(snapshot.entries[0].exifDate == Date(timeIntervalSince1970: 1_706_956_496))
        let plan = BatchRename.plan(
            snapshot.entries,
            names: BatchRename.names(
                snapshot.entries, preset: rename("{exif:HHmm}"), timeZone: TimeZone(secondsFromGMT: 0)!),
            existing: snapshot.existing)
        #expect(plan.rows[0].proposedName == "1034.jpg")
        let skipped = try BatchRenameService.snapshot([url], mediaMetadata: false)
        #expect(skipped.entries[0].exifDate == nil && skipped.entries[0].metadata.isEmpty)
    }

    @Test func planThatDoesNotMatchTheSnapshotIsRefused() throws {
        let scratch = try Scratch()
        let a = try scratch.file("a", "a"), b = try scratch.file("b", "b")
        let snapshotA = try BatchRenameService.snapshot([a]), snapshotB = try BatchRenameService.snapshot([b])
        let planB = BatchRenameService.preview(snapshotB, preset: rename("c"))
        for (plan, snapshot) in [(planB, snapshotA), (BatchRenameService.preview(snapshotA, preset: rename("a")), snapshotA)] {
            do {
                _ = try BatchRenameService.execute(plan, snapshot: snapshot) { _, _ in Issue.record("Nothing may move") }
                Issue.record("A mismatched plan was applied")
            } catch {
                #expect(error.localizedDescription.contains("Resolve every preview error"))
            }
        }
        let blocked = BatchRenameService.preview(snapshotA, preset: rename("b"))
        #expect(!blocked.canApply)
        #expect(throws: BatchRenameError.self) { try BatchRenameService.execute(blocked, snapshot: snapshotA) }
        #expect(scratch.listing() == ["a", "b"] && scratch.read("a") == "a" && scratch.read("b") == "b")
    }

    @Test func sourceReplacedMidBatchStopsAndRestoresTheRest() throws {
        let scratch = try Scratch()
        let files = try ["a", "b"].map { try scratch.file($0, $0) }
        let snapshot = try BatchRenameService.snapshot(files)
        let plan = BatchRename.plan(
            snapshot.entries, names: [.success("a2"), .success("b2")], existing: snapshot.existing, caseSensitive: snapshot.caseSensitive)
        var moves = 0
        do {
            _ = try BatchRenameService.execute(plan, snapshot: snapshot) { from, to in
                moves += 1
                if moves == 1 {  // another app swaps "b" for a new file while "a" is being staged
                    try FileManager.default.removeItem(at: files[1])
                    try scratch.file("b", "replacement")
                }
                try FileManager.default.moveItem(at: from, to: to)
            }
            Issue.record("The replaced source was renamed")
        } catch {
            #expect(error.localizedDescription.contains("changed during the batch"))
        }
        #expect(moves == 1)
        #expect(scratch.listing() == ["a", "b"] && scratch.read("a") == "a" && scratch.read("b") == "replacement")
        #expect(!scratch.listing().contains { $0.hasPrefix(".porpoise-rename-") })
    }

    @Test func failedBatchLeavesNoUndoAndUnchangedFiles() throws {
        let scratch = try Scratch()
        let file = try scratch.file("a", "a")
        let snapshot = try BatchRenameService.snapshot([file])
        let plan = BatchRenameService.preview(snapshot, preset: rename("b"))
        try FileManager.default.removeItem(at: file)
        let controller = FileOperationsController()
        #expect(throws: (any Error).self) {
            try controller.finishBatchRename(BatchRenameService.execute(plan, snapshot: snapshot), snapshot: snapshot)
        }
        #expect(!controller.canUndo && scratch.listing().isEmpty)
    }

    @Test func plannerReportsMissingFailedAndRepeatedNames() {
        let entries = [BatchRenameEntry.named("a"), BatchRenameEntry.named("b"), BatchRenameEntry.named("c")]
        let short = BatchRename.plan(entries, names: [.success("x")], existing: ["/test": ["a", "b", "c"]])
        #expect(short.rows[1].problem == "No proposed name." && short.rows[2].problem == "No proposed name.")
        #expect(short.rows[1].proposedName == "b" && !short.canApply && short.steps.isEmpty)
        let failed = BatchRename.plan(
            [BatchRenameEntry.named("a")], names: [.failure(BatchRenameError.invalid("width metadata is missing"))], existing: ["/test": ["a"]])
        #expect(failed.rows[0].problem == "width metadata is missing" && failed.rows[0].proposedName == "a")
        let twice = BatchRename.plan(
            [BatchRenameEntry.named("a"), BatchRenameEntry.named("A")], names: [.success("x"), .success("y")], existing: ["/test": ["a"]])
        #expect(twice.rows[1].problem == "The same source is selected more than once." && !twice.canApply)
        let sensitive = BatchRename.plan(
            [BatchRenameEntry.named("a"), BatchRenameEntry.named("A")], names: [.success("x"), .success("y")], existing: ["/test": ["a", "A"]],
            caseSensitive: ["/test": true])
        #expect(sensitive.canApply && sensitive.changes.map(\.proposedName) == ["x", "y"])
        let mixed = BatchRename.plan(entries, names: [.success("a"), .success("B"), .success("c")], existing: ["/test": ["a", "b", "c"]])
        #expect(mixed.changes.map(\.proposedName) == ["B"] && mixed.steps.count == 2)
    }

    @Test func emptyFindAndUnknownTokensAreLeftAlone() throws {
        let preset = BatchRenamePreset(
            name: "",
            rules: [
                .replace(find: "", with: "zzz", regex: false, caseSensitive: true), .insert(text: "{unknown}{name", position: -1),
                .remove(position: 99, count: 3), .number(start: -3, step: 1, padding: 3, position: 0),
            ])
        #expect(try BatchRename.name(BatchRenameEntry.named("file.txt"), index: 0, preset: preset) == "-003file{unknown}{name.txt")
        #expect(throws: BatchRenameError.self) {
            try BatchRename.name(
                BatchRenameEntry.named("a"), index: 2,
                preset: BatchRenamePreset(name: "", rules: [.number(start: 0, step: Int.max, padding: 0, position: 0)]))
        }
        #expect(BatchRenameError.invalid("message").errorDescription == "message")
    }
}
