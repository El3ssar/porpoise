import Foundation

/// Service-level capabilities. Item permissions and account grants can further restrict an operation.
/// Kept independent of saved accounts so Help can explain a location before it is connected.
public enum ProviderLocation: String, CaseIterable, Sendable {
    case local, sftp, ftp, smb, s3, drive, dropbox, box, oneDrive

    public var title: String {
        switch self {
        case .local: return "This Mac"
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        case .smb: return "SMB"
        case .s3: return "S3"
        case .drive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .box: return "Box"
        case .oneDrive: return "OneDrive"
        }
    }

    public enum Capability: String, CaseIterable, Sendable {
        case operations, conflicts, quota, expiry, pagination, reconnect
    }

    public enum Support: Equatable, Sendable {
        case supported
        /// The operation is performed by macOS rather than by a Porpoise protocol client.
        case systemManaged(String)
        case unavailable(String)

        public var explanation: String? {
            switch self {
            case .supported: return nil
            case .systemManaged(let reason), .unavailable(let reason): return reason
            }
        }
    }

    public func support(_ capability: Capability) -> Support {
        switch capability {
        case .operations, .conflicts:
            return self == .smb
                ? .systemManaged("SMB files use the Mac's file operations after the share is mounted. The server's permissions still apply.")
                : .supported
        case .quota:
            switch self {
            case .local, .smb: return .systemManaged("Available space comes from the mounted volume; per-user server quotas may differ.")
            case .sftp, .ftp, .s3:
                return .unavailable("Porpoise cannot read an account storage quota for this connection. The server still enforces its limits.")
            default: return .supported
            }
        case .expiry:
            switch self {
            case .drive, .dropbox, .box, .oneDrive: return .supported
            case .smb: return .systemManaged("macOS manages the share's login. Reconnect the share if macOS asks you to sign in again.")
            case .local: return .unavailable("Files on this Mac do not use expiring access tokens.")
            default: return .unavailable("This connection does not refresh OAuth access tokens. Update its saved credentials when they expire.")
            }
        case .pagination:
            switch self {
            case .local, .sftp, .ftp: return .unavailable("The folder is listed in one operation; the protocol adapter does not expose pages.")
            case .smb: return .systemManaged("macOS lists the mounted folder; Porpoise does not manage SMB pages.")
            default: return .supported
            }
        case .reconnect:
            switch self {
            case .local: return .unavailable("Files on this Mac do not need a network connection.")
            case .smb:
                return .systemManaged("macOS reconnects the mounted share. If it is unavailable, reconnect it from Network or Connect to Server.")
            default: return .supported
            }
        }
    }

    public var help: String {
        var paragraphs = ["List, read, write, rename, move and delete are available when your account and the item allow them."]
        if let explanation = support(.operations).explanation { paragraphs.append(explanation) }
        paragraphs.append(
            self == .drive
                ? "Google Drive allows duplicate names. A download to an existing local name is refused; edits check the remote revision before saving."
                : "Renaming to an existing name is refused. Downloads preserve an existing local file. Upload replacement rules depend on the destination and transfer choice."
        )
        if self == .dropbox || self == .oneDrive {
            paragraphs.append("Folder deletion requires confirmation because Porpoise cannot safely undo it for this service.")
        }
        for capability in [Capability.quota, .expiry, .pagination, .reconnect] {
            if let reason = support(capability).explanation { paragraphs.append(reason) }
        }
        return paragraphs.joined(separator: "\n\n")
    }
}
