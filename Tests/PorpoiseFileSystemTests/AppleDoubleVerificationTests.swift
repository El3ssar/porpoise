import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite(.serialized)
struct AppleDoubleVerificationTests {
    @Test(arguments: [FileOperationKind.copy, .move], ["ExFAT", "MS-DOS FAT32"])
    func generatedSidecarsDoNotMakeTheCopyDifferent(_ kind: FileOperationKind, _ fileSystem: String) throws {
        let s = try Scratch()
        let disk = try DiskImage(name: "PPMOVES", megabytes: 64, fileSystem: fileSystem, in: s)
        let source = try s.folder("source")
        let file = try s.file("source/file", "bytes")
        let folder = try s.folder("source/sub")
        for item in [file, folder] {
            let value = Data("metadata".utf8)
            #expect(value.withUnsafeBytes { setxattr(item.path, "com.porpoise.test", $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) } == 0)
        }
        let target = disk.volume.appendingPathComponent("source")
        if fileSystem == "ExFAT" {
            // This host's exFAT driver rejects RENAME_EXCL. Exercise real generated sidecars and
            // move verification independently of that existing publication limitation.
            let receipt = kind == .move ? try LocalMoveRemovalReceipt(source: source) : nil
            #expect(copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL)) == 0)
            if let receipt { try receipt.removeSource(afterVerifying: target) }
        } else {
            let job = FileJob(kind: kind, sources: [source], destinationFolder: disk.volume)
            _ = try job.run()
            #expect(job.errors.isEmpty && job.denied.isEmpty, "\(job.errors); denied=\(job.denied)")
        }
        #expect(try String(contentsOf: target.appendingPathComponent("file"), encoding: .utf8) == "bytes")
        #expect(CopyVerification.isGeneratedAppleDouble(target.appendingPathComponent("._file")))
        #expect(CopyVerification.isGeneratedAppleDouble(target.appendingPathComponent("._sub")))
        if kind == .copy {
            #expect(CopyVerification.verify(source, target).ok)
            try Data(contentsOf: target.appendingPathComponent("._file")).write(to: target.appendingPathComponent("._orphan"))
            #expect(CopyVerification.verify(source, target).mismatches.map(\.path) == ["._orphan"])
            try Data("user data".utf8).write(to: target.appendingPathComponent("._file"))
            #expect(CopyVerification.verify(source, target).mismatches.contains { $0.path == "._file" })
        } else {
            #expect(!FileJob.itemExists(at: source))
        }
    }

    @Test func arbitrarySidecarNamesOnNativeVolumesAreCompared() throws {
        let s = try Scratch()
        try s.file("a/file", "bytes")
        try s.file("b/file", "bytes")
        try s.file("b/._file", "user data")
        #expect(CopyVerification.verify(s.path("a"), s.path("b")).mismatches.map(\.path) == ["._file"])
    }
}
