import Foundation

/// What a kind of connection can and can't do, said plainly in the Connections window so nobody is surprised later
/// (a move that becomes copy-and-delete, a time that isn't kept).
public struct ConnectionCapability: Equatable, Sendable {
    public enum Support: Equatable, Sendable {
        case yes
        case no
        /// Works, with the caveat given.
        case partly(String)
    }

    public var name: String
    public var support: Support

    public init(_ name: String, _ support: Support) {
        self.name = name
        self.support = support
    }

    public static func report(for kind: ConnectionProfile.Kind) -> [ConnectionCapability] {
        switch kind {
        case .sftp:
            return [
                .init("Browse, open and edit files", .yes), .init("Upload and download folders", .yes),
                .init("Rename, move and copy on the server", .yes), .init("Keep modification times and permissions", .yes),
                .init("Symbolic links", .yes), .init("Keys, ssh-agent and ~/.ssh/config", .yes),
                .init("Jump hosts (ProxyJump)", .yes), .init("Reconnect after sleep or network loss", .yes),
            ]
        case .ftp, .ftps:
            return [
                .init("Browse, open and edit files", .yes), .init("Upload and download folders", .yes),
                .init("Rename and move on the server", .yes),
                .init("Copy on the server", .partly("FTP has no copy command: files go through this Mac.")),
                .init("Keep modification times", .partly("Only on servers with MFMT.")), .init("Permissions", .no),
                .init(
                    "Encrypted connection", kind == .ftps ? .yes : .partly("No: plain FTP sends the password unencrypted. Use FTPS where possible.")),
                .init("Reconnect after sleep or network loss", .yes),
            ]
        case .smb:
            return [
                .init("Browse, open and edit files", .yes), .init("Upload and download folders", .yes),
                .init("Rename, move and copy on the server", .yes),
                .init("Mounted by macOS", .partly("The share appears in /Volumes, like in Finder.")),
                .init("Reconnect after sleep or network loss", .partly("macOS reconnects the share; Porpoise mounts it again when it's gone.")),
            ]
        case .s3:
            return [
                .init("Browse, open and edit objects", .yes), .init("Upload and download folders", .partly("Folders are key prefixes.")),
                .init("Copy on the server", .yes), .init("Rename and move", .partly("Done as copy, then delete.")),
                .init("Large files", .partly("Uploaded in parts.")), .init("Permissions and symbolic links", .no),
                .init("Reconnect after sleep or network loss", .yes),
            ]
        }
    }
}
