import Foundation
import PorpoiseCore

/// Publish a complete sibling file with one server rename. Failure must leave the previous target intact;
/// a connection lost after successful publication is resolved by rescanning, rather than blindly retrying.
public protocol SyncRemotePublishing: RemoteProvider {
    /// When a date is requested, set it on the staging file before publication or throw without touching target.
    /// Content/size comparison modes pass nil and do not require the server to support date preservation.
    func publishSyncFile(_ staged: URL, to target: URL, modified: Date?) throws
}

extension SSHProvider: SyncRemotePublishing {
    public func publishSyncFile(_ staged: URL, to target: URL, modified: Date?) throws {
        if let modified {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmm.ss"
            try exec("TZ=UTC touch -m -t \(RemoteParsing.quote(formatter.string(from: modified))) \(shellPath(staged))")
        }
        try exec("mv -f -- \(shellPath(staged)) \(shellPath(target))")
    }
}
