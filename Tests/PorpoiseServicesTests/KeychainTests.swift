import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Logins by server, account and protocol, in a memory store (never the login keychain).
@Suite struct KeychainTests {
    let api = MemoryKeychainAPI()
    private var test: Keychain { Keychain(api: api) }

    private func password(_ scheme: String, account: String = "me") -> String? {
        test.password(server: "nas.invalid", account: account, scheme: scheme)
    }

    private func save(_ password: String, _ scheme: String) {
        test.save(server: "nas.invalid", account: "me", password: password, scheme: scheme)
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
        api.add(server: "nas.invalid", account: "me", password: "smb secret", scheme: "smb")
        #expect(password("ftp") == nil)
        // Saving the FTP login leaves the SMB one alone.
        save("ftp secret", "ftp")
        #expect(api.password(server: "nas.invalid", account: "me", scheme: "smb") == "smb secret")
        #expect(password("ftp") == "ftp secret")
    }

    @Test func itemsSavedWithoutAProtocolAreStillFound() {
        api.add(server: "nas.invalid", account: "me", password: "old version", scheme: nil)
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
