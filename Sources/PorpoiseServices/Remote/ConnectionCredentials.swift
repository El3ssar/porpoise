import Foundation
import PorpoiseCore

/// Where S3 secret keys go: the S3 module's Keychain store, keyed by the account (the profile's id). A protocol here so
/// the connection manager needs no more of that module than this.
public protocol S3SecretStore: Sendable {
    func saveSecret(accessKeyID: String, secretAccessKey: String, accountID: UUID) throws
    func hasSecret(accountID: UUID) -> Bool
    func removeSecret(accountID: UUID) throws
}

/// A profile's secret, in the Keychain: FTP, FTPS and SMB passwords as internet passwords under the server, user and
/// protocol (where Finder and the FTP connection find them too), S3 secret keys through the S3 store.
public final class ConnectionCredentials: @unchecked Sendable {
    public static let shared = ConnectionCredentials(passwords: CredentialStores.passwords())

    let passwords: any PasswordCredentialStore
    /// Set by the S3 module when it registers; nil leaves S3 profiles without a way to keep their key.
    nonisolated(unsafe) public static var s3Store: (any S3SecretStore)?
    private let s3Override: (any S3SecretStore)?
    private var s3: (any S3SecretStore)? { s3Override ?? Self.s3Store }

    init(passwords: any PasswordCredentialStore, s3: (any S3SecretStore)? = nil) {
        self.passwords = passwords
        s3Override = s3
    }

    /// Secrets kept in this process only (tests and review apps).
    public static func inMemory(s3: (any S3SecretStore)? = nil) -> ConnectionCredentials {
        ConnectionCredentials(passwords: MemoryCredentials(), s3: s3)
    }

    enum Failure: LocalizedError {
        case noUser, noS3Store, noAccessKey
        var errorDescription: String? {
            switch self {
            case .noUser: return "Enter the user name the password belongs to."
            case .noS3Store: return "S3 connections aren't available in this version."
            case .noAccessKey: return "Enter the access key ID the secret key belongs to."
            }
        }
    }

    /// Keeps `secret` for `profile` (a password, or the S3 secret access key).
    public func saveSecret(_ secret: String, for profile: ConnectionProfile) throws {
        switch profile.kind {
        case .sftp:
            return
        case .s3:
            guard let s3 else { throw Failure.noS3Store }
            guard let key = profile.accessKeyID?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { throw Failure.noAccessKey }
            try s3.saveSecret(accessKeyID: key, secretAccessKey: secret, accountID: profile.id)
        case .ftp, .ftps, .smb:
            guard let user = profile.user?.trimmingCharacters(in: .whitespaces), !user.isEmpty else { throw Failure.noUser }
            passwords.save(server: profile.server, account: user, password: secret, scheme: profile.kind.rawValue)
        }
    }

    /// Whether a secret is kept for `profile`.
    public func hasSecret(for profile: ConnectionProfile) -> Bool {
        switch profile.kind {
        case .sftp: return false
        case .s3: return s3?.hasSecret(accountID: profile.id) ?? false
        case .ftp, .ftps, .smb: return password(for: profile) != nil
        }
    }

    /// The password kept for an FTP, FTPS or SMB profile.
    func password(for profile: ConnectionProfile) -> String? {
        guard profile.kind != .s3, profile.kind != .sftp, let user = profile.user, !user.isEmpty else { return nil }
        return passwords.password(server: profile.server, account: user, scheme: profile.kind.rawValue)
    }

    func removeSecret(for profile: ConnectionProfile) throws {
        if profile.kind == .s3 { try s3?.removeSecret(accountID: profile.id) }
    }
}
