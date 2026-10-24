import Darwin
import Foundation
import Testing

@testable import PorpoiseServices

@Suite struct OAuthIdleConnectionTests {
    @Test func anIdleClientDoesNotConsumeTheCallbackDeadline() async throws {
        let loopback = try CloudOAuthLoopback()
        defer { loopback.cancel() }
        let idle = socket(AF_INET, SOCK_STREAM, 0)
        try #require(idle >= 0)
        defer { close(idle) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(loopback.redirectURL.port!).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(idle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(result == 0)
        let callback = URL(string: "\(loopback.redirectURL)?state=s&code=c")!
        let receiving = Task { try await loopback.callback(timeout: 2) }
        let browser = Task { try await URLSession.shared.data(from: callback) }
        defer { browser.cancel() }
        #expect(try await receiving.value == callback)
        loopback.finish(.received)
        let (_, response) = try await browser.value
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
