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
            // -c is essential: a missing staging file must never be recreated as an empty replacement.
            script +=
                "TZ=UTC touch -c -m -t \(RemoteParsing.quote(FileFormat.posixString(modified, format: "yyyyMMddHHmm.ss", timeZone: .gmt))) \(source) && "
        }
        try exec(script + "mv -f -- \(source) \(destination)")
    }
}

/// Human-readable FTP listings lose seconds; size/date comparison needs authoritative per-file timestamps.
public protocol RemoteTransferMetadata: RemoteProvider {
    func transferModificationDate(_ remote: URL) throws -> Date
}

/// A live, point lookup before publication, without downloading a whole destination listing.
/// Providers without this capability retain the authoritative fresh-listing check.
public protocol RemoteTransferTargetChecking: RemoteProvider {
    func transferTargetExists(_ target: URL) throws -> Bool
}

extension SSHProvider: RemoteTransferTargetChecking {
    public func transferTargetExists(_ target: URL) throws -> Bool {
        let parent = shellPath(target.deletingLastPathComponent()), path = shellPath(target)
        let output = try exec(
            "[ -d \(parent) ] && [ -r \(parent) ] && [ -x \(parent) ] || exit 1; "
                + "if [ -e \(path) ] || [ -L \(path) ]; then printf yes; else printf no; fi")
        guard output == Data("yes".utf8) || output == Data("no".utf8) else {
            throw RemoteError.failed("Could not check the destination folder.")
        }
        return output == Data("yes".utf8)
    }
}

/// A verified native copy; the engine calls the revision-bound removal only when moving its source.
public struct RemoteTransferNativeCopyResult {
    public let removeSource: () throws -> Void
    public init(removeSource: @escaping () throws -> Void) { self.removeSource = removeSource }
}
/// Optional server-side file copy. Return nil for another connection, letting the shared engine stream it.
/// Conflict resolution and deciding when to remove a moved source remain with the engine.
public protocol RemoteTransferNativeCopy: RemoteProvider {
    func copyTransferFile(_ source: URL, to target: URL, replacing: Bool, modified: Date?) throws -> RemoteTransferNativeCopyResult?
}
