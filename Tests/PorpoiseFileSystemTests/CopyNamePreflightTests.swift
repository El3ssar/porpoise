import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite(.serialized)
struct CopyNamePreflightTests {
    @Test(arguments: ["ExFAT", "MS-DOS FAT32"], [FileOperationKind.copy, .move])
    func nestedPairsAreRefusedBeforeAnyDestinationIsCreated(_ fileSystem: String, _ kind: FileOperationKind) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPNAMES", megabytes: 64, fileSystem: fileSystem, in: s)
        let source = try s.folder("tree")
        try s.file("tree/sub/ordinary", "ordinary bytes")
        try s.file("tree/sub/._ordinary", "user sidecar bytes")
        let job = FileJob(kind: kind, sources: [source], destinationFolder: disk.volume)
        _ = try job.run()
        #expect(job.errors.contains { $0.contains("reserved for file metadata") && $0.contains("tree/sub/._ordinary") })
        #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("tree")))
        #expect(s.read("tree/sub/ordinary") == "ordinary bytes" && s.read("tree/sub/._ordinary") == "user sidecar bytes")
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"], [false, true])
    func aSelectedPairFromDifferentFoldersIsRefusedInEitherOrder(_ fileSystem: String, _ reversed: Bool) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPNAMES", megabytes: 64, fileSystem: fileSystem, in: s)
        let file = try s.file("first/ordinary", "ordinary bytes"), sidecar = try s.file("second/._ordinary", "user sidecar bytes")
        let job = FileJob(kind: .copy, sources: reversed ? [sidecar, file] : [file, sidecar], destinationFolder: disk.volume)
        _ = try job.run()
        #expect(job.errors.count == 2 && job.errors.allSatisfy { $0.contains("reserved for file metadata") })
        #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("ordinary")))
        #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("._ordinary")))
        #expect(s.read("second/._ordinary") == "user sidecar bytes")
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"], [("Foo", "._foo"), ("É", "._é"), ("I", "._ı")])
    func plannedPairsUseTheDrivesCaseInsensitiveNames(_ fileSystem: String, _ pair: (String, String)) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPNAMES", megabytes: 64, fileSystem: fileSystem, in: s)
        let source = try s.folder("tree"), probe = disk.volume.appendingPathComponent("case-probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        try Data().write(to: probe.appendingPathComponent(pair.0))
        #expect(FileJob.itemExists(at: probe.appendingPathComponent(String(pair.1.dropFirst(2)))))
        try s.file("tree/" + pair.0, "ordinary bytes")
        try s.file("tree/" + pair.1, "user sidecar bytes")
        let job = FileJob(kind: .copy, sources: [source], destinationFolder: disk.volume)
        _ = try job.run()
        #expect(job.errors.contains { $0.contains("reserved for file metadata") && $0.contains(pair.1) })
        #expect(!FileJob.itemExists(at: disk.volume.appendingPathComponent("tree")))
        #expect(s.read("tree/" + pair.1) == "user sidecar bytes")
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"], [false, true])
    func anExistingDestinationPairIsProtected(_ fileSystem: String, _ incomingSidecar: Bool) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPNAMES", megabytes: 64, fileSystem: fileSystem, in: s)
        let source = try s.file(incomingSidecar ? "._ordinary" : "ordinary", "incoming")
        let existing = disk.volume.appendingPathComponent(incomingSidecar ? "ordinary" : "._ordinary")
        try Data("existing bytes".utf8).write(to: existing)
        let job = FileJob(kind: .copy, sources: [source], destinationFolder: disk.volume)
        job.resolveConflict = { _ in .init(.overwrite) }
        _ = try job.run()
        #expect(job.errors.contains { $0.contains("reserved for file metadata") })
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing bytes")
        #expect(try String(contentsOf: source, encoding: .utf8) == "incoming")
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"])
    func aNonReservedKeepBothNameIsAllowed(_ fileSystem: String) throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPNAMES", megabytes: 64, fileSystem: fileSystem, in: s)
        let source = try s.file("._ordinary", "user sidecar bytes")
        try Data("counterpart".utf8).write(to: disk.volume.appendingPathComponent("ordinary"))
        try Data("existing sidecar".utf8).write(to: disk.volume.appendingPathComponent("._ordinary"))
        let job = FileJob(kind: .copy, sources: [source], destinationFolder: disk.volume)
        job.resolveConflict = { _ in .init(.rename("kept-user-data")) }
        _ = try job.run()
        #expect(job.errors.isEmpty && job.denied.isEmpty, "\(job.errors)")
        #expect(try String(contentsOf: disk.volume.appendingPathComponent("kept-user-data"), encoding: .utf8) == "user sidecar bytes")
        #expect(try String(contentsOf: disk.volume.appendingPathComponent("._ordinary"), encoding: .utf8) == "existing sidecar")
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"])
    func generatedMetadataIsAllowed(_ fileSystem: String) throws {
        let s = try Scratch()
        let sourceDisk = try DiskImage(name: "PPNAMESRC", megabytes: 64, fileSystem: fileSystem, in: s)
        let targetDisk = try DiskImage(name: "PPNAMEDST", megabytes: 64, fileSystem: fileSystem, in: s)
        let source = sourceDisk.volume.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("ordinary"), metadata = Data("metadata".utf8)
        try Data("ordinary bytes".utf8).write(to: file)
        #expect(metadata.withUnsafeBytes { setxattr(file.path, "com.porpoise.test", $0.baseAddress, metadata.count, 0, 0) } == 0)
        let job = FileJob(kind: .copy, sources: [source], destinationFolder: targetDisk.volume)
        _ = try job.run()
        #expect(job.errors.isEmpty && job.denied.isEmpty, "\(job.errors)")
        #expect(CopyVerification.verify(source, targetDisk.volume.appendingPathComponent("tree")).ok)
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = getxattr(targetDisk.volume.appendingPathComponent("tree/ordinary").path, "com.porpoise.test", &bytes, bytes.count, 0, 0)
        #expect(count == metadata.count)
        if count >= 0 { #expect(Data(bytes.prefix(count)) == metadata) }
    }

    @Test func nativeDestinationsKeepOrdinarySidecarNames() throws {
        let s = try Scratch(), source = try s.folder("tree"), destination = try s.folder("dst")
        try s.file("tree/ordinary", "ordinary bytes")
        try s.file("tree/._ordinary", "user sidecar bytes")
        let job = FileJob(kind: .copy, sources: [source], destinationFolder: destination)
        _ = try job.run()
        #expect(job.errors.isEmpty && job.denied.isEmpty)
        #expect(s.read("dst/tree/ordinary") == "ordinary bytes" && s.read("dst/tree/._ordinary") == "user sidecar bytes")
    }
}

/// Observational metadata-only measurement; fixture creation is outside the clock.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PORPOISE_NAME_PREFLIGHT_BENCHMARK"] == "1"))
struct CopyNamePreflightBenchmarks {
    @Test func fiftyThousandNames() throws {
        let s = try Scratch(), disk = try DiskImage(name: "PPNAMBEN", megabytes: 64, fileSystem: "ExFAT", in: s)
        let source = try s.folder("tree"), root = open(source.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(root) }
        for index in 0..<50_000 {
            let descriptor = openat(root, "f\(index)", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(descriptor)
        }
        for trial in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            try CopyNamePreflight.validateCopy(source, to: disk.volume.appendingPathComponent("tree"), siblings: [source])
            print("W279_PREFLIGHT entries=50000 trial=\(trial) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
        }
    }
}
