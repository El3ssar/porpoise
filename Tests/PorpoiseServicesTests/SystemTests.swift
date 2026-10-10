import Foundation
import SQLite3
import Testing
import PorpoiseTestSupport
import PorpoiseCore
@testable import PorpoiseServices

/// Reading macOS's privacy database: a small TCC.db made in a scratch folder (never the real one).
@Suite(.serialized) final class PrivacyAccessTests {
    let scratch: Scratch
    let db: URL
    let me = Bundle.main.bundleIdentifier ?? "app.porpoise.Porpoise"

    init() throws {
        scratch = try Scratch()
        db = scratch.path("TCC.db")
        // The columns TCC's access table has that Porpoise reads, plus a few it doesn't.
        try Self.sql(db, """
            CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
                auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL,
                PRIMARY KEY (service, client, client_type));
            INSERT INTO access VALUES ('kTCCServiceSystemPolicyAppBundles', '\(me)', 0, 2, 4, 1);
            INSERT INTO access VALUES ('kTCCServiceSystemPolicyAllFiles', 'app.porpoise.Porpoise.helper', 0, 0, 4, 1);
            INSERT INTO access VALUES ('kTCCServiceSystemPolicyAllFiles', 'com.example.other', 0, 2, 4, 1);
            INSERT INTO access VALUES ('kTCCServiceCamera', 'it''s quoted', 0, 3, 4, 1);
            """)
        PrivacyAccess.tccDatabase = db.path
    }

    deinit { PrivacyAccess.tccDatabase = "/Library/Application Support/com.apple.TCC/TCC.db" }

    static func sql(_ file: URL, _ text: String) throws {
        var h: OpaquePointer?
        guard sqlite3_open(file.path, &h) == SQLITE_OK else { throw POSIXError(.EIO) }
        defer { sqlite3_close(h) }
        guard sqlite3_exec(h, text, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EINVAL) }
    }

    @Test func readsTheAuthValueOfARow() {
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles") == 2)   // this app's own row
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAllFiles", client: "com.example.other") == 2)
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAllFiles", client: "app.porpoise.Porpoise.helper") == 0)
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceCamera", client: "it's quoted") == 3)
    }

    @Test func missingRowsAreNil() {
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAllFiles") == nil)
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceNope", client: "com.example.other") == nil)
        #expect(PrivacyAccess.tccAuthValue(service: "", client: "") == nil)
    }

    @Test func valuesAreBoundNotPasted() {
        // SQL in a service or client name is just a name that matches nothing.
        for s in ["x' OR '1'='1", "kTCCServiceCamera' --", "%", "*"] {
            #expect(PrivacyAccess.tccAuthValue(service: s, client: "com.example.other") == nil, "\(s)")
            #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAllFiles", client: s) == nil, "\(s)")
        }
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAllFiles", client: "com.example.other") == 2)   // still there
    }

    @Test func appManagementFromTheDatabase() throws {
        #expect(PrivacyAccess.appManagementState == .allowed)
        try Self.sql(db, "UPDATE access SET auth_value = 0 WHERE service = 'kTCCServiceSystemPolicyAppBundles'")
        #expect(PrivacyAccess.appManagementState == .denied)
    }

    @Test func fullDiskAccessIsWhetherTheDatabaseOpens() throws {
        #expect(PrivacyAccess.hasFullDiskAccess)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: db.path)
        #expect(!PrivacyAccess.hasFullDiskAccess)
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles") == nil)
        PrivacyAccess.tccDatabase = scratch.path("missing.db").path
        #expect(!PrivacyAccess.hasFullDiskAccess)
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles") == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.path("missing.db").path))   // read-only: never created
    }

    @Test func notADatabaseOrNoTable() throws {
        PrivacyAccess.tccDatabase = try scratch.file("junk.db", "this is not sqlite").path
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles") == nil)
        let empty = scratch.path("empty.db")
        try Self.sql(empty, "CREATE TABLE other (x INTEGER)")
        PrivacyAccess.tccDatabase = empty.path
        #expect(PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles") == nil)
    }

    // MARK: The helper's own Full Disk Access

    @Test func helperFullDiskAccessByIdentifierOrPath() throws {
        #expect(PrivilegedHelper.hasFullDiskAccess == false)   // listed, switched off
        try Self.sql(db, "UPDATE access SET auth_value = 2 WHERE client = 'app.porpoise.Porpoise.helper'")
        #expect(PrivilegedHelper.hasFullDiskAccess == true)
        // Recorded by its path instead.
        try Self.sql(db, """
            DELETE FROM access WHERE client = 'app.porpoise.Porpoise.helper';
            INSERT INTO access VALUES ('kTCCServiceSystemPolicyAllFiles', '\(PorpoiseHelperInfo.installedTool)', 1, 2, 4, 1);
            """)
        #expect(PrivilegedHelper.hasFullDiskAccess == true)
        // Not listed at all, but the list is readable: no.
        try Self.sql(db, "DELETE FROM access WHERE service = 'kTCCServiceSystemPolicyAllFiles' AND client_type = 1")
        #expect(PrivilegedHelper.hasFullDiskAccess == false)
        // The list can't be read: unknown.
        PrivacyAccess.tccDatabase = scratch.path("missing.db").path
        #expect(PrivilegedHelper.hasFullDiskAccess == nil)
    }
}

/// The parts of the privileged helper that need no administrator: code hashes and the install script's text.
/// Nothing is installed and nothing runs as root.
@Suite struct PrivilegedHelperTests {
    /// A copy of a small system tool, signed ad hoc (no keychain) with `identifier`.
    func signedTool(_ s: Scratch, _ name: String, identifier: String) throws -> URL {
        let u = s.path(name)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: u.path)
        let r = try Shell.run("/usr/bin/codesign", ["--force", "-s", "-", "-i", identifier, u.path], timeout: 30)
        try #require(r.status == 0, "codesign: \(r.err)")
        return u
    }

    @Test func codeHashOfSignedBinaries() throws {
        let s = try Scratch()
        let a = try signedTool(s, "a", identifier: "app.porpoise.test")
        let b = try signedTool(s, "b", identifier: "app.porpoise.test")
        let c = try signedTool(s, "c", identifier: "app.porpoise.other")
        let ha = try #require(PrivilegedHelper.codeHash(a))
        #expect(ha.count == 40 && ha.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(PrivilegedHelper.codeHash(b) == ha)       // the same code: the same hash
        #expect(PrivilegedHelper.codeHash(c) != ha)       // a different signature: different
        #expect(PrivilegedHelper.codeHash(a) == ha)       // stable
    }

    @Test func codeHashOfABundle() throws {
        let s = try Scratch()
        let app = try s.folder("Helper.app/Contents/MacOS")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Helper").path)
        try s.file("Helper.app/Contents/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.porpoise.test.helper</string>
            <key>CFBundleExecutable</key><string>Helper</string></dict></plist>
            """)
        let r = try Shell.run("/usr/bin/codesign", ["--force", "-s", "-", s.path("Helper.app").path], timeout: 30)
        try #require(r.status == 0, "codesign: \(r.err)")
        #expect(PrivilegedHelper.codeHash(s.path("Helper.app"))?.count == 40)
    }

    @Test func noCodeHashWithoutASignature() throws {
        let s = try Scratch()
        #expect(PrivilegedHelper.codeHash(try s.file("script.sh", "#!/bin/sh\n")) == nil)
        #expect(PrivilegedHelper.codeHash(s.path("missing")) == nil)
        let stripped = s.path("stripped")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: stripped.path)
        _ = try Shell.run("/usr/bin/codesign", ["--remove-signature", stripped.path], timeout: 30)
        #expect(PrivilegedHelper.codeHash(stripped) == nil)
    }

    @Test func installScriptIsValidShellAndQuotesEveryPath() throws {
        let script = PrivilegedHelper.installScript
        #expect(script.hasPrefix("set -e\n"))
        #expect(try Shell.run("/bin/sh", ["-n", "-c", script]).status == 0)
        // The bundled app and plist come in as $1/$2, quoted; never pasted into the text.
        #expect(script.contains(#"/usr/bin/ditto "$1" ""#))
        #expect(script.contains(#"-m 0644 "$2" ""#))
        #expect(!script.contains("Contents/Helpers"))
        // Every path with a space is inside quotes.
        for line in script.split(separator: "\n") where line.contains("Porpoise Helper.app") {
            let unquoted = line.split(separator: "\"", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            #expect(!unquoted.contains { $0.contains("Porpoise Helper") }, "\(line)")
        }
        // Old files go before the new ones are moved in, and the job is loaded last.
        let lines = script.split(separator: "\n").map(String.init)
        let ditto = try #require(lines.firstIndex { $0.contains("ditto") })
        let chown = try #require(lines.firstIndex { $0.contains("chown -R root:wheel") })
        let move = try #require(lines.firstIndex { $0.hasPrefix("/bin/mv ") })
        #expect(lines.firstIndex { $0.contains(#"rm -rf "/Library/PrivilegedHelperTools/Porpoise Helper.app.new""#) }! < ditto)
        #expect(ditto < chown && chown < move)
        #expect(lines.last?.contains("launchctl bootstrap system") == true)
        #expect(lines.allSatisfy { $0.hasPrefix("/") || $0 == "set -e" })   // absolute tools only
    }

    @Test func removeScriptIsValidShell() throws {
        let script = PrivilegedHelper.removeScript
        #expect(try Shell.run("/bin/sh", ["-n", "-c", script]).status == 0)
        #expect(script.contains(#"/bin/rm -rf "\#(PorpoiseHelperInfo.installedApp)""#))
        #expect(script.contains("bootout system/\(PorpoiseHelperInfo.machService)"))
        #expect(script.split(separator: "\n").allSatisfy { $0.hasPrefix("/") })
    }
}

/// Status bar messages.
@Suite struct StatusCenterTests {
    @Test func postsMessagesAndErrors() async {
        let received = Received()
        let token = NotificationCenter.default.addObserver(forName: StatusCenter.message, object: nil, queue: nil) { n in
            received.add(n.object as? String, error: n.userInfo?["error"] as? Bool)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let tag = UUID().uuidString
        StatusCenter.post("hello \(tag)")
        StatusCenter.error("broken \(tag)")
        let mine = received.items.filter { $0.0?.hasSuffix(tag) == true }
        #expect(mine.count == 2)
        #expect(mine.first?.0 == "hello \(tag)" && mine.first?.1 == nil)
        #expect(mine.last?.0 == "broken \(tag)" && mine.last?.1 == true)
    }

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [(String?, Bool?)] = []
        var items: [(String?, Bool?)] { lock.lock(); defer { lock.unlock() }; return _items }
        func add(_ s: String?, error: Bool?) { lock.lock(); _items.append((s, error)); lock.unlock() }
    }
}
