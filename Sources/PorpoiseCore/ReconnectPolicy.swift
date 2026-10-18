import Foundation

/// When a failed remote command is a lost connection worth trying again, and how long to wait between tries. Only a
/// connection that worked before is retried: a wrong address or a refused login fails at once instead of after the
/// whole schedule.
public struct ReconnectPolicy: Sendable {
    /// Seconds to wait before each new try; its length is the number of retries.
    public var delays: [TimeInterval]

    public init(delays: [TimeInterval] = [1, 2, 4, 8, 15]) { self.delays = delays }

    /// No retries (tests that want the first failure).
    public static let never = ReconnectPolicy(delays: [])

    /// ssh exits 255 for its own errors; a remote command's failure has the command's status.
    public static let sshErrorStatus: Int32 = 255

    /// What ssh writes when the network, not the server's answer, ended the command.
    static let sshConnectionLost = [
        "connection reset", "broken pipe", "connection closed by", "connection timed out", "operation timed out",
        "network is unreachable", "no route to host", "connection refused", "could not resolve hostname",
        "timeout, server .*not responding", "kex_exchange_identification", "mux_client_request_session",
        "read from master failed", "connection to .* closed", "software caused connection abort", "host is down",
    ]

    /// Whether ssh's failure (`status`, `stderr`) is a lost connection.
    public static func isConnectionLoss(sshStatus status: Int32, stderr: String) -> Bool {
        guard status == sshErrorStatus else { return false }
        let e = stderr.lowercased()
        // A key the server refused or a changed host key is an answer, not a lost connection.
        if e.contains("permission denied") || e.contains("host key verification failed") || e.contains("identification has changed") {
            return false
        }
        return sshConnectionLost.contains { e.range(of: $0, options: .regularExpression) != nil }
    }

    /// What ssh writes when it never reached the server, so the command never started: safe to retry even for a
    /// command that must not run twice (a rename).
    static let sshNotConnected = [
        "connection refused", "could not resolve hostname", "network is unreachable", "no route to host", "host is down",
        "connect to host .* port .*: operation timed out", "connection timed out during banner exchange", "kex_exchange_identification",
    ]

    /// Whether ssh failed before the command started (see `sshNotConnected`).
    public static func isConnectFailure(sshStatus status: Int32, stderr: String) -> Bool {
        guard isConnectionLoss(sshStatus: status, stderr: stderr) else { return false }
        let e = stderr.lowercased()
        return sshNotConnected.contains { e.range(of: $0, options: .regularExpression) != nil }
    }

    /// curl's exit codes for a connection that failed or broke: resolve (6), connect (7), timeout (28), TLS
    /// handshake (35), empty reply (52), send (55) and receive (56) errors.
    static let curlConnectionLost: Set<Int32> = [6, 7, 28, 35, 52, 55, 56]

    public static func isConnectionLoss(curlStatus status: Int32) -> Bool { curlConnectionLost.contains(status) }

    /// curl's codes for a connection that was never made (resolve, connect).
    public static func isConnectFailure(curlStatus status: Int32) -> Bool { status == 6 || status == 7 }

    /// Runs `attempt` until it succeeds, fails for another reason, or the retries run out. `isLoss` says whether a
    /// failure was a lost connection, `connectedBefore` whether the connection has ever worked; `wait` sleeps (tests
    /// record instead) and `reconnect` runs before each retry (to drop a stale shared connection).
    public func run<T>(
        connectedBefore: () -> Bool, isLoss: (Error) -> Bool, wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        reconnect: () -> Void = {}, _ attempt: () throws -> T
    ) throws -> T {
        var tries = 0
        while true {
            do {
                return try attempt()
            } catch {
                guard tries < delays.count, isLoss(error), connectedBefore() else { throw error }
                wait(delays[tries])
                tries += 1
                reconnect()
            }
        }
    }
}
