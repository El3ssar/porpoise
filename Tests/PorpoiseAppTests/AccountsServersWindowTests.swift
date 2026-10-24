import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// The Accounts & Servers window's servers, over an in-memory profile store and Keychain stand-in (no cloud accounts).
@Suite(.serialized) struct AccountsServersWindowTests {
    static let config = SSHConfig(
        parsing: """
            Host work
              HostName work.example.com
              ProxyJump bastion
            Host bastion
              HostName bastion.example.com
            """)

    @MainActor private func window(_ profiles: ConnectionProfiles, _ credentials: ConnectionCredentials, opened: @escaping (URL) -> Void = { _ in })
        -> AccountsServersWindow
    {
        AccountsServersWindow(profiles: profiles, credentials: credentials, sshConfig: { Self.config }, open: opened)
    }

    @Test @MainActor func anEmptyListSaysWhatToDoNextInTheThemesColors() throws {
        let w = window(ConnectionProfiles(storeURL: nil), .inMemory())
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let views = all(try #require(w.window?.contentView))
        // Not a source list: that draws the system's grey whatever background the theme gives it.
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        #expect(table.style == .inset)
        let add = try #require(views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "connections-empty-add" })
        #expect(add.title == "Add Server")
        add.performClick(nil)
        #expect(w.form != nil)
    }

    @Test @MainActor func addsAnFTPConnectionWithItsPasswordInTheKeychain() throws {
        let profiles = ConnectionProfiles(storeURL: nil)
        let credentials = ConnectionCredentials.inMemory()
        var opened: [URL] = []
        let w = window(profiles, credentials) { opened.append($0) }
        #expect(w.serverRowCount == 0 && w.form == nil)

        w.addProfile(nil)
        let form = try #require(w.form)
        form.choose(.ftps)
        #expect(form.labels == ["Type:", "Name:", "Server:", "Port:", "User:", "Folder:", "Password:"])
        form.type(["Name:": "Files", "Server:": "", "User:": "me", "Password:": "pw-123"])
        #expect(!w.saveForm())  // no server yet
        #expect(form.problemLabel.stringValue.contains("server"))
        form.type(["Server:": "files.example.com"])
        #expect(w.saveForm())

        let saved = try #require(profiles.profiles.first)
        #expect(saved.kind == .ftps && saved.host == "files.example.com" && saved.user == "me")
        #expect(credentials.hasSecret(for: saved))
        #expect(w.serverRowCount == 1)
        #expect(!String(decoding: try JSONEncoder().encode(profiles.profiles), as: UTF8.self).contains("pw-123"))
        w.close()
    }

    @Test @MainActor func importsAnSSHConfigHostWithItsJumpHost() throws {
        let profiles = ConnectionProfiles(storeURL: nil)
        let w = window(profiles, .inMemory())
        #expect(w.importTitles == ["work — work.example.com via bastion", "bastion — bastion.example.com"])
        w.importHost(at: 0)
        #expect(profiles.profiles.map(\.sshAlias) == ["work"])
        #expect(w.importTitles == ["bastion — bastion.example.com"])
        // The alias stays an alias when edited: ssh reads its settings from the file.
        let form = try #require(w.form)
        #expect(form.labels.contains("Jump hosts:"))
        form.type(["Folder:": "projects"])
        #expect(w.saveForm())
        #expect(profiles.profiles.first?.sshAlias == "work" && profiles.profiles.first?.url?.absoluteString == "sftp://work/~/projects")
        w.close()
    }

    @Test @MainActor func everyKindShowsItsFields() throws {
        let w = window(ConnectionProfiles(storeURL: nil), .inMemory())
        w.addProfile(kind: .s3)
        let form = try #require(w.form)
        #expect(form.labels == ["Type:", "Name:", "Endpoint:", "Region:", "Bucket:", "Prefix:", "Access key ID:", "Secret key:"])
        form.type(["Bucket:": "my-bucket", "Endpoint:": "https://s3.example.com", "Access key ID:": "AKIA1"])
        #expect(form.draft.url?.scheme == "s3" && form.draft.accessKeyID == "AKIA1")
        form.choose(.smb)
        #expect(form.labels.contains("Share:") && form.labels.contains("Password:"))
        form.choose(.sftp)
        form.type(["Server:": "h", "Jump hosts:": "a, b ,", "Key file:": "~/.ssh/k"])
        #expect(form.draft.jumpHosts == ["a", "b"] && form.draft.identityFile == "~/.ssh/k" && form.draft.bucket == nil)
        w.close()
    }

    /// The S3 key is kept by the S3 module, under the account in the profile's URL, which S3Location reads.
    @Test @MainActor func anS3ConnectionsKeyIsWhereTheS3ProviderLooks() throws {
        let profiles = ConnectionProfiles(storeURL: nil)
        let w = window(profiles, .shared)
        w.addProfile(kind: .s3)
        let form = try #require(w.form)
        form.type([
            "Name:": "Backups", "Endpoint:": "http://127.0.0.1:9000", "Region:": "eu-west-1", "Bucket:": "backups", "Prefix:": "daily",
            "Access key ID:": "AKIATEST", "Secret key:": "s3-secret-for-test",
        ])
        #expect(w.saveForm())
        let p = try #require(profiles.profiles.first)
        let url = try #require(p.url)
        let location = try #require(S3Location(url: url))
        #expect(location.bucket == "backups" && location.key == "daily/" && location.region == "eu-west-1")
        #expect(location.endpoint.absoluteString == "http://127.0.0.1:9000" && location.accountID == p.id)
        let keys = try S3Credentials.read(accountID: location.accountID)
        #expect(keys.accessKeyID == "AKIATEST" && keys.secretAccessKey == "s3-secret-for-test")
        #expect(ConnectionCredentials.shared.hasSecret(for: p))
        profiles.remove(p.id)
        #expect(throws: (any Error).self) { try S3Credentials.read(accountID: p.id) }
        w.close()
    }

    @Test @MainActor func connectSavesAndOpens() throws {
        let profiles = ConnectionProfiles(storeURL: nil)
        let p = ConnectionProfile(name: "NAS", kind: .smb, host: "nas.local", user: "me", path: "Public")
        profiles.save(p)
        var opened: [URL] = []
        let w = window(profiles, .inMemory()) { opened.append($0) }
        #expect(w.form?.draft == p)
        w.connectProfile(nil)
        #expect(opened == [p.url!])
        w.close()
    }

    @Test @MainActor func failedSaveKeepsDraftAndDoesNotConnectThenRetries() throws {
        let scratch = try Scratch("connection-form-failure")
        let parent = try scratch.file("parent", "not a directory")
        let file = parent.appendingPathComponent("connections.json")
        let profiles = ConnectionProfiles(storeURL: file)
        var opened: [URL] = []
        let w = window(profiles, .inMemory()) { opened.append($0) }
        defer { w.close() }
        w.addProfile(nil)
        let form = try #require(w.form)
        form.type(["Name:": "Work", "Server:": "work.example.com"])
        let draft = form.draft
        #expect(!w.saveForm())
        #expect(w.form === form && w.form?.draft == draft)
        #expect(form.problemLabel.stringValue.contains("wasn’t saved"))
        #expect(profiles.profiles.isEmpty && w.serverRowCount == 0)
        w.connectProfile(nil)
        #expect(opened.isEmpty)
        try FileManager.default.removeItem(at: parent)
        #expect(w.saveForm())
        #expect(ConnectionProfiles(storeURL: file).profiles == [draft])
        #expect(w.serverRowCount == 1)
        w.connectProfile(nil)
        #expect(opened == [draft.url!])
    }

    /// W-243 (dialogs #21): a connection that fails to save leaves no password behind in the Keychain.
    @Test @MainActor func aFailedSaveLeavesNoOrphanedPassword() throws {
        let scratch = try Scratch("connection-secret-orphan")
        let parent = try scratch.file("parent", "not a directory")
        let profiles = ConnectionProfiles(storeURL: parent.appendingPathComponent("connections.json"))
        let credentials = ConnectionCredentials.inMemory()
        let w = window(profiles, credentials)
        defer { w.close() }
        w.addProfile(nil)
        let form = try #require(w.form)
        form.choose(.ftps)
        form.type(["Name:": "Files", "Server:": "files.example.com", "User:": "me", "Password:": "pw-123"])
        let draft = form.draft
        #expect(!w.saveForm())
        #expect(!credentials.hasSecret(for: draft))
        try FileManager.default.removeItem(at: parent)
        #expect(w.saveForm())
        #expect(credentials.hasSecret(for: draft))
    }

    @Test @MainActor func failedImportRemainsAnUnsavedEditableDraft() throws {
        let scratch = try Scratch("connection-import-failure")
        let parent = try scratch.file("parent", "not a directory")
        let profiles = ConnectionProfiles(storeURL: parent.appendingPathComponent("connections.json"))
        let w = window(profiles, .inMemory())
        defer { w.close() }
        w.importHost(at: 0)
        #expect(profiles.profiles.isEmpty)
        #expect(w.form?.draft.sshAlias == "work")
        #expect(w.form?.problemLabel.stringValue.contains("wasn’t saved") == true)
        #expect(w.importTitles.count == 2)
        try FileManager.default.removeItem(at: parent)
        #expect(w.saveForm())
        #expect(profiles.profiles.first?.sshAlias == "work")
    }

    @Test @MainActor func infoDescribesTheRouteAndCapabilities() {
        let p = ConnectionProfile(name: "x", kind: .sftp, host: "h")
        let e = HostKeys.Effective(values: ["hostname": ["10.0.0.5"], "port": ["2200"], "user": ["me"], "proxyjump": ["gw"]])
        #expect(ConnectionInfoView.route(e, profile: p) == "Connects to 10.0.0.5:2200 as me via gw.")
        #expect(ConnectionInfoView.route(nil, profile: p).contains("couldn't"))
        let info = ConnectionInfoView(profile: ConnectionProfile(name: "F", kind: .ftp, host: "f", user: "u"), credentials: .inMemory())
        let texts = info.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts.contains("What it can do") && texts.contains { $0.contains("unencrypted") })
    }

    @Test @MainActor func connectSheetSavesServersAsConnections() throws {
        let form = ServerForm(kind: .sftp)
        form.server.stringValue = "web.example.com"
        let p = try #require(form.profile())
        #expect(p.kind == .sftp && p.host == "web.example.com" && p.name == "web.example.com" && p.port == nil)
        #expect(ServerForm(kind: .webdav).profile() == nil)
        #expect(ServerForm(kind: .sftp).profile() == nil)  // no server
    }

    /// ux #8: one window lists every cloud account and every saved server, each under its heading, and shows the
    /// selected one's settings; the headings can't be chosen.
    @Test @MainActor func listsCloudAccountsAndServersInOneWindow() throws {
        let previous = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = DemoCloudBackend(accounts: [
            CloudAccount(id: "one", email: "one@example.invalid", displayName: "One"),
            CloudAccount(id: "two", email: "two@example.invalid", displayName: "Two"),
        ])
        defer { CloudAccounts.shared.backend = previous }
        let profiles = ConnectionProfiles(storeURL: nil)
        let server = ConnectionProfile(name: "Work", kind: .sftp, host: "work.example.com")
        try profiles.save(server).get()
        let w = window(profiles, .inMemory())
        defer { w.close() }
        #expect(
            w.entries == [
                .heading(AccountsServersWindow.accountsHeading), .account("one"), .account("two"), .heading(AccountsServersWindow.serversHeading),
                .server(server.id),
            ])
        #expect(w.accountRowCount == 2 && w.serverRowCount == 1)
        // An account first: its settings, no server form.
        #expect(w.selection == .account("one") && w.accountDetail?.accountID == "one" && w.form == nil)
        w.select(.server(server.id))
        #expect(w.selection == .server(server.id) && w.form?.draft.host == "work.example.com" && w.accountDetail == nil)
        w.select(.heading(AccountsServersWindow.serversHeading))
        #expect(w.selection == .server(server.id))
        w.select(.account("two"))
        #expect(w.accountDetail?.accountID == "two")
        // A server or account that isn't there (a stale link): the first row there is, not "No accounts or servers".
        w.select(.server(UUID()))
        #expect(w.selection == .account("one") && w.accountDetail?.accountID == "one")
        w.select(.account("gone"))
        #expect(w.selection == .account("one"))
        // Signed out elsewhere (the sidebar's menu): the window shows the next row there is.
        CloudAccounts.shared.backend = DemoCloudBackend(accounts: [CloudAccount(id: "one", email: "one@example.invalid", displayName: "One")])
        #expect(w.entries.contains(.account("two")) == false)
        #expect(w.selection == .account("one"))
    }

    /// "+" adds either kind: a cloud account (through the Connect sheet's sign-in) or a server filled in here.
    @Test @MainActor func addOffersACloudAccountOrAServer() throws {
        let w = window(ConnectionProfiles(storeURL: nil), .inMemory())
        defer { w.close() }
        let menu = w.addMenu()
        #expect(menu.items.map(\.title) == ["Cloud Account…", "Server"])
        let server = try #require(menu.items.last)
        _ = server.target?.perform(server.action, with: server)
        #expect(w.form?.draft.kind == .sftp)
        let cloud = try #require(menu.items.first)
        _ = cloud.target?.perform(cloud.action, with: cloud)
        let sheet = try #require(ConnectSheet.current)
        defer { sheet.window?.close() }
        #expect(sheet.page == .pick)
    }

    /// Go › Accounts & Servers… is ⌥⌘K; ⌘K stays the quick Connect sheet.
    @Test @MainActor func theGoMenuOpensBothDoors() throws {
        let menu = AppDelegate.shared.buildMainMenu()
        let go = try #require(menu.items.first { $0.title == "Go" }?.submenu)
        let window = try #require(go.items.first { $0.action == #selector(MainWindowController.showConnections(_:)) })
        #expect(window.title == "Accounts & Servers…")
        #expect(window.keyEquivalent == "k" && window.keyEquivalentModifierMask == [.command, .option])
        let sheet = try #require(go.items.first { $0.action == #selector(MainWindowController.connectToServer(_:)) })
        #expect(sheet.title == "Connect to Server…" && sheet.keyEquivalent == "k" && sheet.keyEquivalentModifierMask == [.command])
    }
}
