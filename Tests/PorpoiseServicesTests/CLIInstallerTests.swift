import Foundation
import XCTest

@testable import PorpoiseServices

final class CLIInstallerTests: XCTestCase {
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
