import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

struct MoveGenerationSafetyTests {
    @Test(arguments: ["edit", "replace", "child", "directoryReplace", "unchanged", "corrupt"])
    func crossVolumeMoveRetainsChangedGeneration(_ change: String) throws {
        let scratch = try Scratch()
        let disk = try DiskImage(in: scratch)
        let directory = change == "child" || change == "directoryReplace"
        let source = directory ? try scratch.folder("source") : try scratch.file("source", "old bytes")
        if directory { try scratch.file("source/old", "old bytes") }
        let target = disk.volume.appendingPathComponent("source")
        let job = FileJob(kind: .move, sources: [source], destinationFolder: disk.volume)
        job.onEvent = { event in
            guard case .placed = event else { return }
            do {
                switch change {
                case "edit": try Data("new unsent bytes".utf8).write(to: source)
                case "replace":
                    try FileManager.default.removeItem(at: source)
                    try Data("replacement".utf8).write(to: source, options: .atomic)
                case "child": try scratch.file("source/new", "new unsent bytes")
                case "directoryReplace":
                    try FileManager.default.moveItem(at: source, to: scratch.path("previous"))
                    try scratch.folder("source")
                case "corrupt": try Data("corruption".utf8).write(to: target)
                default: break
                }
            } catch { Issue.record(error) }
        }
        _ = try job.run()
        if change == "unchanged" {
            #expect(job.errors.isEmpty && !FileJob.itemExists(at: source))
        } else {
            #expect(FileJob.itemExists(at: source))
            #expect(job.errors.contains { $0.contains("source retained") })
        }
        if change != "corrupt" {
            #expect(try String(contentsOf: directory ? target.appendingPathComponent("old") : target, encoding: .utf8) == "old bytes")
        }
        if change == "child" { #expect(scratch.read("source/new") == "new unsent bytes") }
    }

    @Test func aMergedCrossVolumeMoveReportsANewChildAndKeepsIt() throws {
        let scratch = try Scratch(), disk = try DiskImage(in: scratch)
        let source = try scratch.folder("source")
        try scratch.file("source/old", "old bytes")
        let target = disk.volume.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("previous".utf8).write(to: target.appendingPathComponent("old"))
        let job = FileJob(kind: .move, sources: [source], destinationFolder: disk.volume)
        job.resolveConflict = { .init($0.source.isDirectory ? .writeInto : .overwrite) }
        job.disposeReplacedItem = { displaced, _ in
            try scratch.file("source/new", "new unsent bytes")
            try FileManager.default.removeItem(at: displaced)
        }
        _ = try job.run()
        #expect(scratch.read("source/new") == "new unsent bytes")
        #expect(try String(contentsOf: target.appendingPathComponent("old"), encoding: .utf8) == "old bytes")
        #expect(job.errors.contains { $0.contains("source retained") })
    }

    @Test func nestedIntentionalSkipsAreNotReportedAsSourceChanges() throws {
        let scratch = try Scratch()
        let source = try scratch.folder("src/source")
        try scratch.file("src/source/sub/file", "incoming")
        let destination = try scratch.folder("dst")
        try scratch.file("dst/source/sub/file", "existing")
        let job = FileJob(kind: .move, sources: [source], destinationFolder: destination)
        job.resolveConflict = { .init($0.source.isDirectory ? .writeInto : .skip) }
        _ = try job.run()
        #expect(job.errors.isEmpty)
        #expect(scratch.read("src/source/sub/file") == "incoming")
        #expect(scratch.read("dst/source/sub/file") == "existing")
    }

    @Test func receiptRejectsSameBytesAtAReplacementInode() throws {
        let scratch = try Scratch()
        let source = try scratch.file("source", "same")
        let receipt = try LocalMoveRemovalReceipt(source: source)
        let copy = try scratch.file("copy", "same")
        try FileManager.default.moveItem(at: source, to: scratch.path("previous"))
        try scratch.file("source", "same")
        #expect(throws: (any Error).self) { try receipt.removeSource(afterVerifying: copy) }
        #expect(scratch.read("source") == "same")
    }

    @Test func emptyDirectoryRemovalKeepsNewChildrenAndReplacement() throws {
        let scratch = try Scratch()
        let source = try scratch.folder("source")
        let receipt = try LocalMoveRemovalReceipt(source: source)
        try scratch.file("source/new", "new")
        #expect(throws: (any Error).self) { try receipt.removeEmptyDirectory() }
        #expect(scratch.read("source/new") == "new")
        try FileManager.default.moveItem(at: source, to: scratch.path("previous"))
        try scratch.folder("source")
        #expect(throws: (any Error).self) { try receipt.removeEmptyDirectory() }
        #expect(FileJob.itemExists(at: source))
    }
}
