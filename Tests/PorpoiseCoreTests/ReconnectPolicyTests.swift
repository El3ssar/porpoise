import Foundation
import Testing

@testable import PorpoiseCore

@Suite struct ReconnectPolicyTests {
    struct Lost: Error {}
    struct Other: Error {}

    @Test func classifiesSSHFailures() {
        let loss = [
            "client_loop: send disconnect: Broken pipe", "Connection reset by peer", "Connection to 10.0.0.5 closed by remote host.",
            "ssh: connect to host h port 22: Operation timed out", "ssh: Could not resolve hostname h: nodename nor servname provided",
            "mux_client_request_session: read from master failed: Broken pipe", "Timeout, server h not responding.",
            "kex_exchange_identification: read: Connection reset by peer",
        ]
        for e in loss { #expect(ReconnectPolicy.isConnectionLoss(sshStatus: 255, stderr: e), "\(e)") }
        // A remote command's own failure, a refused login and a changed key are answers.
        #expect(!ReconnectPolicy.isConnectionLoss(sshStatus: 1, stderr: "Connection reset by peer"))
        #expect(!ReconnectPolicy.isConnectionLoss(sshStatus: 255, stderr: "user@h: Permission denied (publickey)."))
        #expect(!ReconnectPolicy.isConnectionLoss(sshStatus: 255, stderr: "Host key verification failed."))
        #expect(!ReconnectPolicy.isConnectionLoss(sshStatus: 255, stderr: "Bad configuration option: x"))
        // Only failures before the server was reached are safe for commands that mustn't run twice.
        #expect(ReconnectPolicy.isConnectFailure(sshStatus: 255, stderr: "ssh: connect to host h port 22: Connection refused"))
        #expect(ReconnectPolicy.isConnectFailure(sshStatus: 255, stderr: "ssh: connect to host h port 22: Operation timed out"))
        #expect(!ReconnectPolicy.isConnectFailure(sshStatus: 255, stderr: "client_loop: send disconnect: Broken pipe"))
        #expect(!ReconnectPolicy.isConnectFailure(sshStatus: 255, stderr: "Permission denied"))
    }

    @Test func classifiesCurlFailures() {
        for code: Int32 in [6, 7, 28, 35, 52, 55, 56] { #expect(ReconnectPolicy.isConnectionLoss(curlStatus: code)) }
        for code: Int32 in [0, 9, 67, 78] { #expect(!ReconnectPolicy.isConnectionLoss(curlStatus: code)) }
        #expect(ReconnectPolicy.isConnectFailure(curlStatus: 7) && !ReconnectPolicy.isConnectFailure(curlStatus: 56))
    }

    @Test func retriesALostConnectionThatWorkedBefore() throws {
        var waits: [TimeInterval] = []
        var reconnects = 0
        var calls = 0
        let r = try ReconnectPolicy(delays: [1, 2, 4]).run(
            connectedBefore: { true }, isLoss: { $0 is Lost }, wait: { waits.append($0) }, reconnect: { reconnects += 1 }
        ) {
            calls += 1
            if calls < 3 { throw Lost() }
            return "done"
        }
        #expect(r == "done" && calls == 3 && waits == [1, 2] && reconnects == 2)
    }

    @Test func givesUpAfterTheSchedule() {
        var calls = 0
        #expect(throws: Lost.self) {
            try ReconnectPolicy(delays: [0, 0]).run(connectedBefore: { true }, isLoss: { $0 is Lost }, wait: { _ in }) {
                calls += 1
                throw Lost()
            }
        }
        #expect(calls == 3)
    }

    @Test func otherFailuresAndFirstConnectionsFailAtOnce() {
        var calls = 0
        #expect(throws: Other.self) {
            try ReconnectPolicy().run(connectedBefore: { true }, isLoss: { $0 is Lost }, wait: { _ in }) {
                calls += 1; throw Other()
            }
        }
        #expect(throws: Lost.self) {
            try ReconnectPolicy().run(connectedBefore: { false }, isLoss: { $0 is Lost }, wait: { _ in }) {
                calls += 1; throw Lost()
            }
        }
        #expect(throws: Lost.self) {
            try ReconnectPolicy.never.run(connectedBefore: { true }, isLoss: { $0 is Lost }, wait: { _ in }) {
                calls += 1; throw Lost()
            }
        }
        #expect(calls == 3)
        #expect(ReconnectPolicy().delays.reduce(0, +) <= 30)
    }
}
