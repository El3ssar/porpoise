import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct AppPathIdentityTests {
    @Test func sameFileKeyIgnoresPrivateAndKeepsRemoteURLsWhole() throws {
        #expect(FilePath.key(URL(fileURLWithPath: "/private/tmp/x")) == FilePath.entry("/tmp/x"))
        #expect(FilePath.key(URL(fileURLWithPath: "/tmp/x")) == FilePath.entry("/tmp/x"))
        #expect(FilePath.key(URL(fileURLWithPath: "/privateer/x")) == "/privateer/x")
        let remote = try #require(URL(string: "sftp://me@host/private/tmp/x"))
        #expect(FilePath.key(remote) == "sftp://me@host/private/tmp/x")
    }
}
