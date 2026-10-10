import Foundation
import Security
import Testing
@testable import PorpoiseServices

/// Logins by server, account and protocol, in a throwaway keychain (never the login keychain).
@Suite struct KeychainTests {
    let test: TestKeychain
    init() throws { test = try TestKeychain() }

    private func password(_ scheme: String, account: String = "me") -> String? {
        Keychain.password(server: "nas.invalid", account: account, scheme: scheme, in: test.keychain)
    }

    private func save(_ password: String, _ scheme: String) {
        Keychain.save(server: "nas.invalid", account: "me", password: password, scheme: scheme, in: test.keychain)
    }

    @Test func savesAndUpdatesPerProtocol() {
        #expect(password("ftp") == nil)
        save("first", "ftp")
        save("tls", "ftps")
        #expect(password("ftp") == "first" && password("ftps") == "tls")
        save("second", "ftp")
        #expect(password("ftp") == "second" && password("ftps") == "tls")
        #expect(password("ftp", account: "someone else") == nil)
    }

    @Test func anotherProtocolsPasswordIsNeverSentOverFTP() {
        test.add(server: "nas.invalid", account: "me", password: "smb secret", protocol: kSecAttrProtocolSMB)
        #expect(password("ftp") == nil)
        // Saving the FTP login leaves the SMB one alone.
        save("ftp secret", "ftp")
        #expect(test.password(server: "nas.invalid", account: "me", protocol: kSecAttrProtocolSMB) == "smb secret")
        #expect(password("ftp") == "ftp secret")
    }

    @Test func itemsSavedWithoutAProtocolAreStillFound() {
        test.add(server: "nas.invalid", account: "me", password: "old version", protocol: nil)
        #expect(password("ftp") == "old version")
        // Once saved with a protocol, that one wins.
        save("new", "ftp")
        #expect(password("ftp") == "new")
    }

    @Test func passwordsAreKeptExactly() {
        let odd = "pässwörd \"quoted\" \\ with\nnewline 🔑"
        save(odd, "ftp")
        #expect(password("ftp") == odd)
    }
}
