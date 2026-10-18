import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// An S3 key store in memory, standing in for the S3 module's Keychain store.
final class MemoryS3Secrets: S3SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var keys: [UUID: (String, String)] = [:]
    func saveSecret(accessKeyID: String, secretAccessKey: String, accountID: UUID) throws {
        lock.withLock { keys[accountID] = (accessKeyID, secretAccessKey) }
    }
    func hasSecret(accountID: UUID) -> Bool { lock.withLock { keys[accountID] != nil } }
    func removeSecret(accountID: UUID) throws { _ = lock.withLock { keys.removeValue(forKey: accountID) } }
}

@Suite struct ConnectionProfilesTests {
    let scratch: Scratch
    let file: URL
    let passwords = MemoryCredentials()
    let s3 = MemoryS3Secrets()
    var credentials: ConnectionCredentials { ConnectionCredentials(passwords: passwords, s3: s3) }

    init() throws {
        scratch = try Scratch("profiles")
        file = scratch.path("connections.json")
    }

    static let sftp = ConnectionProfile(name: "Web", kind: .sftp, host: "web.example.com", user: "deploy", jumpHosts: ["ops@bastion:2200"])
    static let ftp = ConnectionProfile(name: "Files", kind: .ftps, host: "files.example.com", user: "me")
    static let smb = ConnectionProfile(name: "NAS", kind: .smb, host: "nas.local", user: "me", path: "Public")
    static let s3Profile = ConnectionProfile(
        name: "Backups", kind: .s3, bucket: "backups", endpoint: "https://s3.example.com", region: "eu-west-1", accessKeyID: "AKIAEXAMPLE")

    @Test func savedProfilesComeBackAndHoldNoSecrets() throws {
        let store = ConnectionProfiles(storeURL: file)
        for p in [Self.sftp, Self.ftp, Self.smb, Self.s3Profile] { store.save(p) }
        try credentials.saveSecret("ftp-pass-123", for: Self.ftp)
        try credentials.saveSecret("smb-pass-456", for: Self.smb)
        try credentials.saveSecret("s3-secret-789", for: Self.s3Profile)

        let again = ConnectionProfiles(storeURL: file)
        #expect(again.profiles == [Self.sftp, Self.ftp, Self.smb, Self.s3Profile])
        let json = try String(contentsOf: file, encoding: .utf8)
        for secret in ["ftp-pass-123", "smb-pass-456", "s3-secret-789"] { #expect(!json.contains(secret)) }
        // Nor in the defaults.
        for key in Settings.store.dictionaryRepresentation().keys {
            let value = "\(Settings.store.object(forKey: key) ?? "")"
            #expect(!value.contains("ftp-pass-123") && !value.contains("s3-secret-789"))
        }
        // Where they are: the Keychain (here, its memory stand-in), under the server and protocol.
        #expect(passwords.password(server: "files.example.com", account: "me", scheme: "ftps") == "ftp-pass-123")
        #expect(passwords.password(server: "nas.local", account: "me", scheme: "smb") == "smb-pass-456")
        #expect(s3.keys[Self.s3Profile.id].map { [$0.0, $0.1] } == ["AKIAEXAMPLE", "s3-secret-789"])
        for p in [Self.ftp, Self.smb, Self.s3Profile] { #expect(credentials.hasSecret(for: p)) }
        #expect(!credentials.hasSecret(for: Self.sftp))
    }

    @Test func editingRemovingAndOrdering() async throws {
        let store = ConnectionProfiles(storeURL: file)
        let notes = ConnectionMonitorTests.Counter()
        let o = NotificationCenter.default.addObserver(forName: ConnectionProfiles.changed, object: store, queue: nil) { _ in notes.add() }
        defer { NotificationCenter.default.removeObserver(o) }
        store.save(Self.sftp)
        store.save(Self.s3Profile)
        try credentials.saveSecret("s", for: Self.s3Profile)
        var renamed = Self.sftp
        renamed.name = "Web (prod)"
        store.save(renamed)
        #expect(store.profiles.map(\.name) == ["Web (prod)", "Backups"])
        store.move(Self.s3Profile.id, to: 0)
        #expect(store.profiles.map(\.name) == ["Backups", "Web (prod)"])
        store.move(UUID(), to: 0)
        store.remove(Self.s3Profile.id, credentials: credentials)
        #expect(store.profiles.map(\.name) == ["Web (prod)"])
        // An S3 key belongs to its profile alone, so it goes with it.
        #expect(s3.keys.isEmpty)
        store.remove(UUID(), credentials: credentials)
        // Every change but removing a profile that isn't there.
        #expect(await eventually { notes.value == 6 })
        #expect(ConnectionProfiles(storeURL: file).profile(Self.sftp.id)?.name == "Web (prod)")
    }

    @Test func anUnreadableFileIsKeptAside() throws {
        try scratch.file("connections.json", "{ not json")
        let store = ConnectionProfiles(storeURL: file)
        #expect(store.profiles.isEmpty)
        #expect(scratch.read("connections.unreadable.json") == "{ not json")
        store.save(Self.ftp)
        #expect(ConnectionProfiles(storeURL: file).profiles == [Self.ftp])
    }

    @Test func aURLFindsItsProfileAndSSHOptions() {
        let store = ConnectionProfiles(storeURL: nil)
        store.save(Self.sftp)
        var keyed = ConnectionProfile(name: "Keyed", kind: .sftp, host: "k.example.com", identityFile: "~/.ssh/k")
        store.save(keyed)
        #expect(store.profile(for: URL(string: "sftp://deploy@web.example.com/srv")!)?.id == Self.sftp.id)
        #expect(store.sshOptions(for: URL(string: "sftp://deploy@web.example.com/")!) == ["-J", "ops@bastion:2200"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(store.sshOptions(for: URL(string: "sftp://k.example.com/")!) == ["-i", home + "/.ssh/k", "-o", "IdentitiesOnly=yes"])
        #expect(store.sshOptions(for: URL(string: "sftp://other/")!).isEmpty)
        keyed.identityFile = "  "
        store.save(keyed)
        #expect(store.sshOptions(for: URL(string: "sftp://k.example.com/")!).isEmpty)
        // Profiles of other kinds give ssh nothing.
        store.save(ConnectionProfile(name: "F", kind: .ftp, host: "f"))
        #expect(store.sshOptions(for: URL(string: "ftp://f/")!).isEmpty)
    }

    @Test func profilesAreSidebarRowsInRemote() async throws {
        let store = ConnectionProfiles(storeURL: nil)
        store.save(Self.sftp)
        store.save(ConnectionProfile(name: "", kind: .ftp, host: "broken"))  // incomplete: no row
        store.save(Self.smb)
        #expect(store.placeEntries.map(\.title) == ["Web", "NAS"])
        #expect(store.placeEntries.allSatisfy { $0.section == .remote })

        let places = PlacesModel(storeURL: scratch.path("places.json"), profiles: store)
        let remote = places.sections().first { $0.0 == .remote }?.1 ?? []
        #expect(remote.map(\.title).suffix(2) == ["Web", "NAS"])
        // A profile also bookmarked shows once, as the bookmark.
        places.add(Self.smb.url!, title: "My NAS")
        #expect(places.allEntries.filter { $0.url == Self.smb.url! }.map(\.title) == ["My NAS"])

        let changed = ConnectionMonitorTests.Counter()
        let o = NotificationCenter.default.addObserver(forName: PlacesModel.changed, object: nil, queue: nil) { _ in changed.add() }
        defer { NotificationCenter.default.removeObserver(o) }
        store.save(Self.ftp)  // posted on the main thread
        #expect(await eventually { changed.value > 0 })
    }

    @Test func secretsNeedTheirIdentity() throws {
        let noUser = ConnectionProfile(name: "F", kind: .ftp, host: "f")
        #expect(throws: (any Error).self) { try credentials.saveSecret("p", for: noUser) }
        var noKey = Self.s3Profile
        noKey.accessKeyID = " "
        #expect(throws: (any Error).self) { try credentials.saveSecret("p", for: noKey) }
        let withoutS3 = ConnectionCredentials(passwords: passwords)
        let saved = ConnectionCredentials.s3Store
        ConnectionCredentials.s3Store = nil
        defer { ConnectionCredentials.s3Store = saved }
        #expect(throws: (any Error).self) { try withoutS3.saveSecret("p", for: Self.s3Profile) }
        #expect(!withoutS3.hasSecret(for: Self.s3Profile))
        // SFTP keeps nothing: ssh uses keys and the agent, and asks for a password itself.
        try credentials.saveSecret("p", for: Self.sftp)
        #expect(credentials.password(for: Self.sftp) == nil)
        for error in [ConnectionCredentials.Failure.noUser, .noS3Store, .noAccessKey] { #expect(error.errorDescription?.isEmpty == false) }
    }

    @Test func smbMountsUseTheSavedLogin() throws {
        let store = ConnectionProfiles(storeURL: nil)
        store.save(Self.smb)
        let url = Self.smb.url!
        #expect(NetworkMounts.login(for: url, profiles: store, credentials: credentials) == nil)
        try credentials.saveSecret("pw", for: Self.smb)
        let login = NetworkMounts.login(for: url, profiles: store, credentials: credentials)
        #expect(login?.user == "me" && login?.password == "pw")
        #expect(NetworkMounts.login(for: URL(string: "smb://other/Public")!, profiles: store, credentials: credentials) == nil)
    }

    @Test func keychainProtocols() {
        #expect(Keychain.proto("ftp") == kSecAttrProtocolFTP)
        #expect(Keychain.proto("ftps") == kSecAttrProtocolFTPS)
        #expect(Keychain.proto("smb") == kSecAttrProtocolSMB)
    }
}
