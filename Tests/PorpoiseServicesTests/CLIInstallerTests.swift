import Foundation
import XCTest

@testable import PorpoiseServices

final class CLIInstallerTests: XCTestCase {
    func testUnwritableDirectoryIsNotReportedAsAnExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executable = dir.appendingPathComponent("cli"), bin = dir.appendingPathComponent("bin")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bin.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.path) }
        XCTAssertThrowsError(try CLIInstaller.install(executable: executable, destination: bin.appendingPathComponent("porpoise"))) { error in
            guard case CLIInstaller.Failure.cannotInstall = error else { return XCTFail("Expected a write failure, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("porpoise").path))
    }

    func testInstallIsIdempotentAndNeverReplacesUserFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executable = dir.appendingPathComponent("cli with space")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let destination = dir.appendingPathComponent("bin/porpoise")
        try CLIInstaller.install(executable: executable, destination: destination)
        try CLIInstaller.install(executable: executable, destination: destination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), executable.path)
        try FileManager.default.removeItem(at: destination)
        try Data("user content".utf8).write(to: destination)
        XCTAssertThrowsError(try CLIInstaller.install(executable: executable, destination: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "user content")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "/nonexistent")
        XCTAssertThrowsError(try CLIInstaller.install(executable: executable, destination: destination))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "/nonexistent")
    }
}
