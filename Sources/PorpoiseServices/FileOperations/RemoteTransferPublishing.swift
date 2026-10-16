import Foundation
import PorpoiseCore

/// Publish a complete sibling file with one server rename. Failure must leave the previous target intact;
/// a connection lost after successful publication is resolved by rescanning, rather than blindly retrying.
public protocol RemoteTransferPublishing: RemoteProvider {
    /// When a date is requested, set it on the staging file before publication or throw without touching target.
    /// Content/size comparison modes pass nil and do not require the server to support date preservation.
    func publishTransferFile(_ staged: URL, to target: URL, modified: Date?) throws
}

extension SSHProvider: RemoteTransferPublishing {
    public func publishTransferFile(_ staged: URL, to target: URL, modified: Date?) throws {
        let source = shellPath(staged), destination = shellPath(target)
        var script = "if [ ! -f \(source) ] || [ -L \(source) ] || [ -d \(destination) ]; then exit 1; fi; "
        if let modified {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmm.ss"
            // -c is essential: a missing staging file must never be recreated as an empty replacement.
            script += "TZ=UTC touch -c -m -t \(RemoteParsing.quote(formatter.string(from: modified))) \(source) && "
        }
        try exec(script + "mv -f -- \(source) \(destination)")
    }
}

/// Human-readable FTP listings lose seconds; size/date comparison needs authoritative per-file timestamps.
public protocol RemoteTransferMetadata: RemoteProvider {
    func transferModificationDate(_ remote: URL) throws -> Date
}
