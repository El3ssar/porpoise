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
    public func canRecoverSyncDeletions(in root: URL) throws -> Bool {
        let rootPath = shellPath(root), trash = shellPath(root.appendingPathComponent(".porpoise-trash"))
        let check =
            "if [ -e \(trash) ] || [ -L \(trash) ]; then if [ -d \(trash) ] && [ ! -L \(trash) ] && [ -w \(trash) ] && [ -x \(trash) ]; then printf yes; else printf no; fi; else if [ -d \(rootPath) ] && [ -w \(rootPath) ] && [ -x \(rootPath) ]; then printf yes; else printf no; fi; fi"
        return String(decoding: try exec(check), as: UTF8.self) == "yes"
    }

    public func publishSyncFile(_ staged: URL, to target: URL, modified: Date?) throws {
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

/// Human-readable FTP listings lose seconds; size/date sync needs authoritative per-file timestamps.
public protocol SyncRemoteMetadata: RemoteProvider {
    func syncModificationDate(_ remote: URL) throws -> Date
}
