import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// FTP runs curl once per command, so reconnecting is running curl again: after a lost connection, if the server was
/// reached before, and only for commands that are safe to repeat unless curl never connected.
@Suite(.serialized) struct FTPReconnectTests {
    let curl: RecordingTool

    init() throws { curl = try RecordingTool() }

    private func provider(_ waits: @escaping (TimeInterval) -> Void = { _ in }) -> FTPProvider {
        let p = FTPProvider(
            url: URL(string: "ftp://h.invalid/")!, curl: curl.path, credentialStore: MemoryCredentials(), reconnect: ReconnectPolicy(delays: [1, 2]))
        p.wait = waits
        return p
    }

    static let listing = "-rw-r--r--    1 ftp      ftp            12 Mar  1  2024 a.txt\r\n"

    @Test func aListingRunsAgainAfterTheConnectionDrops() throws {
        try curl.reply(Self.listing)
        try curl.reply("", status: 56, call: 1)  // receive error: the connection broke
        try curl.reply("", status: 7, call: 2)  // couldn't connect: the network isn't back yet
        nonisolated(unsafe) var waits: [TimeInterval] = []
        let p = provider { waits.append($0) }
        _ = try p.list(URL(string: "ftp://h.invalid/")!)
        let items = try p.list(URL(string: "ftp://h.invalid/")!)
        #expect(items.map(\.name) == ["a.txt"])
        #expect(curl.calls.count == 4 && waits == [1, 2])
    }

    @Test func aRenameIsNotRepeatedAfterTheConnectionBrokeMidway() throws {
        try curl.reply(Self.listing)
        try curl.reply("", status: 56, call: 2)
        let p = provider()
        _ = try p.list(URL(string: "ftp://h.invalid/")!)
        // rename lists the folder (call 1) to check the new name is free, then sends RNFR/RNTO (call 2), which breaks.
        #expect(throws: (any Error).self) { try p.rename(URL(string: "ftp://h.invalid/a.txt")!, to: "b.txt") }
        #expect(curl.calls.count == 3)
    }

    @Test func aRenameIsRetriedWhenCurlNeverConnected() throws {
        try curl.reply(Self.listing)
        try curl.reply("", status: 7, call: 2)
        let p = provider()
        _ = try p.list(URL(string: "ftp://h.invalid/")!)
        try p.rename(URL(string: "ftp://h.invalid/a.txt")!, to: "b.txt")
        #expect(curl.calls.count == 4)
        #expect(curl.calls[3].args.contains("RNFR a.txt"))
    }

    @Test func aServerNeverReachedFailsAtOnce() throws {
        try curl.reply("", status: 7)
        nonisolated(unsafe) var waited = false
        #expect(throws: (any Error).self) { try provider { _ in waited = true }.list(URL(string: "ftp://h.invalid/")!) }
        #expect(!waited && curl.calls.count == 1)
    }
}
