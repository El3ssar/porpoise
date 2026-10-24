import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Exercises the actual account-store disconnect guard without launching an external editor.
@MainActor func checkCloudCopyDisconnect(root: URL, disconnect: () async throws -> Void) async throws -> URL {
    let scratch = try Scratch("view-only-account-copy")
    let cached = try scratch.file("export.pdf", "server bytes")
    let store = RemoteOpenCopyStore(remote: URL(string: "https://fixture.invalid/export")!, root: root)
    let local = try await store.copy(cached)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
    try Data("local annotation".utf8).write(to: local)
    await #expect(throws: CloudConnectionError.unsentEdits) { try await disconnect() }
    #expect(try String(contentsOf: local, encoding: .utf8) == "local annotation")
    #expect(try String(contentsOf: cached, encoding: .utf8) == "server bytes")
    try Data("server bytes".utf8).write(to: local)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: local.path)
    return local
}
