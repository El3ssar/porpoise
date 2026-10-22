import Foundation
import PorpoiseCore

struct TransferConnectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Use only for reads and writes inside an owned staging area. Never wraps publication or source removal.
enum TransferRetry {
    static func isConnectionFailure(_ error: Error) -> Bool {
        if error is TransferConnectionError { return true }
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed].contains(
                error.code)
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return [ECONNRESET, ECONNREFUSED, ENETDOWN, ENETUNREACH, EHOSTUNREACH, ETIMEDOUT, EPIPE].contains(Int32(ns.code))
        }
        guard let remote = error as? RemoteError, case .failed(let text) = remote else { return false }
        let lower = text.lowercased()
        return [
            "connection reset", "connection refused", "connection closed", "connection timed out", "broken pipe", "network is unreachable",
            "no route to host", "could not resolve hostname",
        ].contains { lower.contains($0) }
    }

    static func run<T>(control: JobControl, notice: (String?) -> Void, _ body: () throws -> T) throws -> T {
        var attempt = 0
        while true {
            try control.checkpoint()
            do { let value = try body(); if attempt > 0 { notice(nil) }; return value } catch {
                guard !control.isCancelled, isConnectionFailure(error), attempt < control.policy.retries else { throw error }
                attempt += 1
                let delay = control.policy.delay(forRetry: attempt)
                control.recordRetry(attempt, delay: delay)
                notice("Waiting for network · retry \(attempt)/\(control.policy.retries) in \(String(format: "%.2f", delay)) s")
                let end = ProcessInfo.processInfo.systemUptime + delay
                repeat {
                    try control.checkpoint()
                    Thread.sleep(forTimeInterval: min(0.02, max(0, end - ProcessInfo.processInfo.systemUptime)))
                } while ProcessInfo.processInfo.systemUptime < end
            }
        }
    }
}
