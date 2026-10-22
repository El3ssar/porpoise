import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

struct FileJobRuleMetadataTests {
    @Test(arguments: [FileOperationKind.copy, .move], [false, true])
    func filteredFoldersKeepMetadataWhetherOrNotTheSourceSurvives(_ kind: FileOperationKind, _ excludesChild: Bool) throws {
        let scratch = try Scratch("filtered-metadata")
        let source = try scratch.folder("source")
        try scratch.file("source/keep", "complete bytes")
        if excludesChild { try scratch.file("source/cache.tmp", "retained bytes") }
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o750, .modificationDate: date], ofItemAtPath: source.path)
        let value = Array("kept".utf8)
        #expect(setxattr(source.path, "com.porpoise.rules", value, value.count, 0, 0) == 0)
        let destination = try scratch.folder("destination")
        let job = FileJob(
            kind: kind, sources: [source], destinationFolder: destination,
            control: JobControl(policy: .init(exclusions: ["*.tmp"])))
        job.allowsClone = false
        _ = try job.run()
        #expect(job.errors.isEmpty && job.denied.isEmpty)
        #expect(scratch.read("destination/source/keep") == "complete bytes")
        #expect(scratch.read("destination/source/cache.tmp") == nil)
        #expect(scratch.listing("destination") == ["source"])
        let target = destination.appendingPathComponent("source")
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o750)
        #expect((attributes[.modificationDate] as? Date) == date)
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = getxattr(target.path, "com.porpoise.rules", &buffer, buffer.count, 0, 0)
        #expect(count == 4 && String(decoding: buffer.prefix(max(0, count)), as: UTF8.self) == "kept")
        #expect(FileManager.default.fileExists(atPath: source.path) == (kind == .copy || excludesChild))
        if excludesChild { #expect(scratch.read("source/cache.tmp") == "retained bytes") }
    }
}
