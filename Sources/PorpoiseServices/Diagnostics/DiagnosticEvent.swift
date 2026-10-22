import Foundation

/// An operation-local correlation, generated independently of account/file identifiers. There is deliberately no
/// string/UUID initializer: callers must not reuse a provider's opaque ID or another piece of user data here.
public struct DiagnosticCorrelation: Hashable, Encodable, Sendable {
    private let value: UUID
    public init() { value = UUID() }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The only error detail retained. Never use localizedDescription, userInfo, a custom error's domain or type name.
public enum DiagnosticFailure: String, Encodable, Sendable, CaseIterable {
    case none, cancelled, permission, notFound, noSpace, network, authentication, conflict, timeout, unavailable, unknown

    public init(error: any Error) {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain:
            switch error.code {
            case NSUserCancelledError: self = .cancelled
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: self = .permission
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: self = .notFound
            case NSFileWriteOutOfSpaceError: self = .noSpace
            case NSFileWriteFileExistsError: self = .conflict
            default: self = .unknown
            }
        case NSURLErrorDomain:
            switch error.code {
            case NSURLErrorCancelled: self = .cancelled
            case NSURLErrorTimedOut: self = .timeout
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: self = .authentication
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                self = .network
            case NSURLErrorResourceUnavailable: self = .unavailable
            default: self = .unknown
            }
        default: self = .unknown
        }
    }
}

/// Numeric app/build versions and OS components only. Bundle names, paths, device/user names, environment and git
/// working-directory information are never inspected. Unexpected version formats become "unknown" as a whole.
public struct DiagnosticIdentity: Encodable, Sendable, Equatable {
    public let version: String
    public let build: String
    public let osVersion: String
    public let architecture: String

    public static var current: Self {
        Self(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    public init(version: String?, build: String?) {
        self.version = Self.numericVersion(version)
        self.build = Self.numericVersion(build)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "unknown"
        #endif
    }

    private static func numericVersion(_ raw: String?) -> String {
        guard let raw, raw.utf8.count <= 19 else { return "unknown" }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count),
            parts.allSatisfy({
                (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) }
            })
        else { return "unknown" }
        return raw
    }
}

/// A closed schema: adding freeform messages, paths, URLs, commands, account IDs or arbitrary attributes here
/// would defeat the privacy boundary. Add a reviewed enum case instead of interpolating a runtime string.
public struct DiagnosticEvent: Encodable, Sendable {
    public enum Code: String, Encodable, Sendable, CaseIterable {
        case persistenceWriteFailed = "persistence.write_failed"
        case providerConnected = "provider.connected"
        case providerDisconnected = "provider.disconnected"
        case subprocessExited = "subprocess.exited"
        case helperUnavailable = "helper.unavailable"
        case recoveryStarted = "recovery.started"
        case recoveryFinished = "recovery.finished"
    }

    public let timestamp: Date
    public let code: Code
    public let failure: DiagnosticFailure
    public let correlation: DiagnosticCorrelation

    init(timestamp: Date, code: Code, failure: DiagnosticFailure, correlation: DiagnosticCorrelation) {
        self.timestamp = timestamp
        self.code = code
        self.failure = failure
        self.correlation = correlation
    }
}
