import Darwin
import Foundation
import PorpoiseCore
import XCTest

@testable import PorpoiseServices

final class AutomationSocketTests: XCTestCase {
    private func directory() -> URL { URL(fileURLWithPath: "/tmp/pa-\(UUID().uuidString)") }

    func testPrivateEndpointRoundTripAndExclusiveOwnership() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try AutomationServer(directory: dir) { request, _ in
            AutomationResponse(id: request.id, paths: request.paths)
        }
        try withExtendedLifetime(server) {
            XCTAssertThrowsError(try AutomationServer(directory: dir) { request, _ in AutomationResponse(id: request.id) }) {
                XCTAssertEqual($0 as? AutomationError, .busy)
            }
            let paths = ["/tmp/quote'\"", "/tmp/new\nline", "/tmp/日本語", "/tmp/$(touch INJECTED)"]
            let response = try AutomationSocket.send(AutomationRequest(action: .reveal, paths: paths), directory: dir)
            XCTAssertEqual(response.paths, paths)
            var info = stat()
            XCTAssertEqual(lstat(dir.appendingPathComponent("automation.sock").path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
        }
    }

    func testRejectsUnsafeDirectoryAndSymlinks() throws {
        let dir = directory(), link = directory()
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        chmod(dir.path, 0o755)
        XCTAssertThrowsError(try AutomationServer(directory: dir) { request, _ in AutomationResponse(id: request.id) })
        chmod(dir.path, 0o700)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        XCTAssertThrowsError(try AutomationServer(directory: link) { request, _ in AutomationResponse(id: request.id) })
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("lock"), withDestinationURL: dir.appendingPathComponent("target"))
        XCTAssertThrowsError(try AutomationServer(directory: dir) { request, _ in AutomationResponse(id: request.id) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("target").path))
    }

    func testDeadlineAndResponseIdentity() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try AutomationServer(directory: dir) { request, _ in
            if request.action == .selection { return AutomationResponse(id: UUID()) }
            try? await Task.sleep(for: .milliseconds(100))
            return AutomationResponse(id: request.id)
        }
        try withExtendedLifetime(server) {
            XCTAssertThrowsError(try AutomationSocket.send(.init(action: .selection), directory: dir)) {
                XCTAssertEqual($0 as? AutomationError, .invalidResponse)
            }
            XCTAssertThrowsError(try AutomationSocket.send(.init(action: .open, paths: ["/tmp"]), directory: dir, timeout: 0.02)) {
                XCTAssertEqual($0 as? AutomationError, .timedOut)
            }
        }
    }

    func testOversizedFrameRejectedBeforeAllocation() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        try AutomationSocket.configure(pair[0])
        var header = UInt32(AutomationSocket.maximumFrame + 1).bigEndian
        _ = withUnsafeBytes(of: &header) { Darwin.write(pair[1], $0.baseAddress, $0.count) }
        XCTAssertThrowsError(try AutomationSocket.readFrame(pair[0], deadline: Date().addingTimeInterval(1))) {
            XCTAssertEqual($0 as? AutomationError, .oversized)
        }
    }
}
