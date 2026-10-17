import CoreGraphics
import Foundation
import ImageIO
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing
import UniformTypeIdentifiers

@testable import PorpoiseCore
@testable import PorpoiseServices

@Suite(.isolatedSettings) struct BatchRenameTests {
    private func entry(_ name: String, directory: Bool = false) -> BatchRenameEntry {
        BatchRenameEntry(url: URL(fileURLWithPath: "/test/" + name), isDirectory: directory)
    }
    @Test func orderedRulesRegexCapturesAndExtensions() throws {
        let input = entry("IMG_2026.JPG")
        let preset = BatchRenamePreset(
            name: "Photos",
            rules: [
                .replace(find: #"^IMG_(\d+)$"#, with: "Photo-$1", regex: true, caseSensitive: true),
                .changeCase(.lower), .insert(text: "x-", position: 0), .number(start: 7, step: 2, padding: 3, position: -1),
            ], extensionMode: .lowercase)
        #expect(try BatchRename.name(input, index: 2, preset: preset) == "x-photo-2026011.jpg")
        var change = BatchRenamePreset(name: "", rules: [.template("{name}-{ext}")], extensionMode: .change("png"))
        #expect(try BatchRename.name(input, index: 0, preset: change) == "IMG_2026-JPG.png")
        change.extensionMode = .includeInRules; change.rules = [.replace(find: ".JPG", with: ".png", regex: false, caseSensitive: false)]
        #expect(try BatchRename.name(input, index: 0, preset: change) == "IMG_2026.png")
        change.extensionMode = .change("png"); change.rules = []
        #expect(try BatchRename.name(entry("folder.v1", directory: true), index: 0, preset: change) == "folder.v1")
    }
    @Test func regexMetadataIsLiteralWhileCaptureGroupsStillExpand() throws {
        var input = entry("a.txt"); input.metadata["title"] = "$1\\name"
        let preset = BatchRenamePreset(name: "", rules: [.replace(find: "(a)", with: "{title}-$1", regex: true, caseSensitive: true)])
        #expect(try BatchRename.name(input, index: 0, preset: preset) == "$1\\name-a.txt")
    }

    @Test func unicodeCharacterPositionsAndAllCaseModes() throws {
        let input = entry("👩🏽‍🚀e\u{301}X.txt")
        let rules: [BatchRenameRule] = [.remove(position: 0, count: 1), .insert(text: "🚀", position: 1)]
        #expect(try BatchRename.name(input, index: 0, preset: BatchRenamePreset(name: "", rules: rules)) == "e\u{301}🚀X.txt")
        for (mode, result) in [
            (RenameCase.lower, "hello world"), (.upper, "HELLO WORLD"), (.title, "Hello World"), (.sentence, "Hello world"),
            (.unchanged, "hELLO wORLD"),
        ] {
            #expect(try BatchRename.name(entry("hELLO wORLD"), index: 0, preset: BatchRenamePreset(name: "", rules: [.changeCase(mode)])) == result)
        }
    }
    @Test func datesMetadataAndMissingMetadata() throws {
        var input = entry("photo.jpg")
        input.created = Date(timeIntervalSince1970: 0); input.modified = Date(timeIntervalSince1970: 86400);
        input.exifDate = Date(timeIntervalSince1970: 172800)
        input.metadata = ["width": "640", "height": "480", "artist": "Artist", "album": "Album", "title": "Title"]
        let preset = BatchRenamePreset(
            name: "", rules: [.template("{created:yyyyMMdd}-{modified:yyyyMMdd}-{exif:yyyyMMdd}-{width}x{height}-{artist}-{album}-{title}")])
        #expect(
            try BatchRename.name(input, index: 0, preset: preset, timeZone: TimeZone(secondsFromGMT: 0)!)
                == "19700101-19700102-19700103-640x480-Artist-Album-Title.jpg")
        #expect(throws: (any Error).self) { try BatchRename.name(entry("none"), index: 0, preset: preset) }
    }
    @Test func invalidRegexNumbersAndPositionsBlock() {
        let rules: [BatchRenameRule] = [
            .replace(find: "[", with: "", regex: true, caseSensitive: true), .number(start: Int.max, step: 1, padding: 1, position: 0),
            .number(start: 1, step: 1, padding: 100, position: 0), .insert(text: "x", position: -2), .remove(position: -1, count: 1),
        ]
        for rule in rules {
            #expect(throws: (any Error).self) { try BatchRename.name(entry("a"), index: 1, preset: BatchRenamePreset(name: "", rules: [rule])) }
        }
    }
    @Test func collisionsCasePolicyAndUnicodeEquivalence() {
        let entries = [entry("a"), entry("b")]
        let duplicate = BatchRename.plan(entries, names: [.success("same"), .success("SAME")], existing: ["/test": ["a", "b"]])
        #expect(!duplicate.canApply && duplicate.rows.allSatisfy { $0.problem != nil })
        let sensitive = BatchRename.plan(
            entries, names: [.success("same"), .success("SAME")], existing: ["/test": ["a", "b"]], caseSensitive: ["/test": true])
        #expect(sensitive.canApply)
        let unicode = BatchRename.plan(
            entries, names: [.success("café"), .success("cafe\u{301}")], existing: ["/test": ["a", "b"]], caseSensitive: ["/test": true])
        #expect(!unicode.canApply)
        let occupant = BatchRename.plan([entry("a")], names: [.success("TAKEN")], existing: ["/test": ["a", "taken"]])
        #expect(!occupant.canApply && occupant.rows[0].problem != nil)
        let unchanged = BatchRename.plan(entries, names: [.success("b"), .success("b")], existing: ["/test": ["a", "b"]])
        #expect(!unchanged.canApply)
    }
    @Test func invalidNamesAndNestedSelectionsBlock() {
        for name in ["", ".", "..", "a/b", "a\0b", String(repeating: "x", count: 256)] {
            #expect(!BatchRename.plan([entry("a")], names: [.success(name)], existing: ["/test": ["a"]]).canApply)
        }
        let nested = [entry("folder", directory: true), entry("folder/child")]
        #expect(!BatchRename.plan(nested, names: [.success("renamed"), .success("newchild")], existing: [:]).canApply)
    }
    @Test func pureSwapCyclePlanAndSafeTemporaryNames() {
        let entries = [entry("a"), entry("b"), entry("c")]
        let plan = BatchRename.plan(
            entries, names: [.success("b"), .success("c"), .success("a")], existing: ["/test": ["a", "b", "c", ".porpoise-rename-t-0"]], token: "../t"
        )
        #expect(plan.canApply && plan.steps.count == 6)
        #expect(plan.steps.prefix(3).allSatisfy { $0.to.deletingLastPathComponent().path == "/test" })
        #expect(plan.steps[0].to.lastPathComponent == ".porpoise-rename-t-0-")
        #expect(plan.steps[3].from == plan.steps[0].to && plan.steps[3].to.lastPathComponent == "b")
    }
    @Test(arguments: [2, 3]) func swapCycleAndWholeBatchUndoRedoOnDisk(count: Int) throws {
        let scratch = try Scratch()
        let names = Array(["a", "b", "c"].prefix(count))
        let targets = Array(names.dropFirst()) + [names[0]]
        let urls = try names.map { try scratch.file($0, $0) }
        let snapshot = try BatchRenameService.snapshot(urls)
        let plan = BatchRename.plan(
            snapshot.entries, names: targets.map { .success($0) }, existing: snapshot.existing, caseSensitive: snapshot.caseSensitive)
        let controller = FileOperationsController()
        let output = try controller.batchRename(plan, snapshot: snapshot)
        #expect(output.map(\.lastPathComponent) == targets)
        for (name, target) in zip(names, targets) { #expect(scratch.read(target) == name) }
        #expect(controller.undoTitle == "Undo: Batch Rename")
        controller.undo(window: nil)
        for name in names { #expect(scratch.read(name) == name) }
        #expect(!controller.canUndo && controller.redoTitle == "Redo: Batch Rename")
        controller.redo(window: nil)
        for (name, target) in zip(names, targets) { #expect(scratch.read(target) == name) }
        #expect(scratch.listing() == names)
    }

    @Test func realCaseOnlyUnicodeAndDanglingSymlinkCollisions() throws {
        let scratch = try Scratch()
        let file = try scratch.file("readme.txt", "data")
        var snapshot = try BatchRenameService.snapshot([file])
        var plan = BatchRenameService.preview(
            snapshot, preset: BatchRenamePreset(name: "", rules: [.changeCase(.upper)], extensionMode: .includeInRules))
        let result = try BatchRenameService.execute(plan, snapshot: snapshot)
        #expect(scratch.listing() == ["README.TXT"] && scratch.read("README.TXT") == "data")
        _ = try FileActions.undo(try #require(result.undo))
        #expect(scratch.listing() == ["readme.txt"])
        try scratch.file("cafe\u{301}.txt", "occupied")
        try scratch.symlink("dead", to: "/definitely-missing-target")
        snapshot = try BatchRenameService.snapshot([file])
        for name in ["café.txt", "dead"] {
            plan = BatchRename.plan(snapshot.entries, names: [.success(name)], existing: snapshot.existing, caseSensitive: snapshot.caseSensitive)
            #expect(!plan.canApply)
        }
        #expect(scratch.read("café.txt") == "occupied")
    }
    @Test func lateTargetAndReplacedSourceAreRejected() throws {
        let scratch = try Scratch()
        let file = try scratch.file("a", "original")
        let snapshot = try BatchRenameService.snapshot([file])
        let plan = BatchRenameService.preview(snapshot, preset: BatchRenamePreset(name: "", rules: [.template("new")]))
        try scratch.file("new", "external")
        #expect(throws: (any Error).self) { try BatchRenameService.execute(plan, snapshot: snapshot) }
        #expect(scratch.read("a") == "original" && scratch.read("new") == "external")
        try FileManager.default.moveItem(at: file, to: scratch.path("saved-original"))
        try scratch.file("a", "replacement")
        #expect(throws: (any Error).self) { try BatchRenameService.execute(plan, snapshot: snapshot) }
        #expect(scratch.read("a") == "replacement" && scratch.read("saved-original") == "original")
    }
    @Test func failedExecutionRollsBackEveryStagedSource() throws {
        let scratch = try Scratch()
        let files = try ["a", "b"].map { try scratch.file($0, $0) }
        let snapshot = try BatchRenameService.snapshot(files)
        let plan = BatchRename.plan(
            snapshot.entries, names: [.success("b"), .success("a")], existing: snapshot.existing, caseSensitive: snapshot.caseSensitive)
        var count = 0
        #expect(throws: (any Error).self) {
            try BatchRenameService.execute(plan, snapshot: snapshot) { from, to in
                count += 1
                if count == 4 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            }
        }
        #expect(scratch.listing() == ["a", "b"] && scratch.read("a") == "a" && scratch.read("b") == "b")
    }
    @Test func imageDimensionsAndExifDateFromRealFile() throws {
        let scratch = try Scratch()
        let url = scratch.path("photo.jpg")
        let context = try #require(
            CGContext(
                data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:02:03 12:34:56"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let snapshot = try BatchRenameService.snapshot([url])
        #expect(snapshot.entries[0].metadata["width"] == "3" && snapshot.entries[0].metadata["height"] == "2")
        #expect(snapshot.entries[0].exifDate != nil)
        let plan = BatchRenameService.preview(snapshot, preset: BatchRenamePreset(name: "", rules: [.template("{exif:yyyyMMdd}-{width}x{height}")]))
        #expect(plan.rows[0].proposedName == "20240203-3x2.jpg" && plan.canApply)
    }
    @Test func targetCreatedDuringExecutionNeverOverwrites() throws {
        let scratch = try Scratch()
        let file = try scratch.file("a", "original")
        let snapshot = try BatchRenameService.snapshot([file])
        let plan = BatchRenameService.preview(snapshot, preset: BatchRenamePreset(name: "", rules: [.template("new")]))
        var moves = 0
        #expect(throws: (any Error).self) {
            try BatchRenameService.execute(plan, snapshot: snapshot) { from, to in
                moves += 1
                if moves == 2 { try scratch.file("new", "racing writer") }
                try FileManager.default.moveItem(at: from, to: to)
            }
        }
        #expect(scratch.read("a") == "original" && scratch.read("new") == "racing writer")
        #expect(!scratch.listing().contains { $0.hasPrefix(".porpoise-rename-") })
    }
    @Test func rollbackFailureReportsRecoveryPathAndKeepsEveryFile() throws {
        let scratch = try Scratch()
        let file = try scratch.file("a", "original")
        let snapshot = try BatchRenameService.snapshot([file])
        let plan = BatchRenameService.preview(snapshot, preset: BatchRenamePreset(name: "", rules: [.template("new")]))
        var moves = 0
        do {
            _ = try BatchRenameService.execute(plan, snapshot: snapshot) { from, to in
                moves += 1
                if moves == 2 { try scratch.file("a", "racing writer"); throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            }
            Issue.record("Expected a rollback failure")
        } catch {
            #expect(error.localizedDescription.contains("Recovery paths:"))
            let stagingName = try #require(scratch.listing().first { $0.hasPrefix(".porpoise-rename-") })
            #expect(scratch.read(stagingName) == "original" && scratch.read("a") == "racing writer")
        }
    }

    @Test func failedUndoPreservesBatchAndCanRetry() throws {
        let scratch = try Scratch()
        let source = try scratch.file("a", "original")
        let snapshot = try BatchRenameService.snapshot([source])
        let plan = BatchRenameService.preview(snapshot, preset: BatchRenamePreset(name: "", rules: [.template("new")]))
        let controller = FileOperationsController()
        try controller.batchRename(plan, snapshot: snapshot)
        try scratch.file("a", "external")
        controller.undo(window: nil)
        #expect(controller.canUndo && !controller.canRedo)
        #expect(scratch.read("new") == "original" && scratch.read("a") == "external")
        try FileManager.default.removeItem(at: source)
        controller.undo(window: nil)
        #expect(!controller.canUndo && controller.canRedo && scratch.read("a") == "original")
        #expect(scratch.listing() == ["a"])
    }
    @Test func selectedDanglingSymlinkIsRenamedAsALink() throws {
        let scratch = try Scratch()
        let link = try scratch.symlink("link", to: "/definitely-missing-target")
        let snapshot = try BatchRenameService.snapshot([link])
        let plan = BatchRenameService.preview(snapshot, preset: BatchRenamePreset(name: "", rules: [.template("renamed")]))
        let result = try BatchRenameService.execute(plan, snapshot: snapshot)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: result.urls[0].path) == "/definitely-missing-target")
        _ = try FileActions.undo(try #require(result.undo))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/definitely-missing-target")
    }

    @Test func presetsPersistAndReset() throws {
        let preset = BatchRenamePreset(name: "Numbered", rules: [.number(start: 10, step: 2, padding: 4, position: -1)], extensionMode: .lowercase)
        Settings.shared.saveBatchRenamePreset(preset)
        #expect(Settings.shared.batchRenamePresets == [preset])
        var replacement = preset; replacement.rules = [.changeCase(.title)]
        Settings.shared.saveBatchRenamePreset(replacement)
        #expect(Settings.shared.batchRenamePresets == [replacement])
        #expect(try JSONDecoder().decode(BatchRenamePreset.self, from: JSONEncoder().encode(replacement)) == replacement)
        Settings.shared.resetAll(); #expect(Settings.shared.batchRenamePresets.isEmpty)
    }
}
