import Foundation
import Testing

@testable import PorpoiseCore

@Suite struct HostKeyFingerprintTests {
    /// A throwaway key and the fingerprint `ssh-keygen -l` gives it.
    static let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHt8HxJz3v+AK7I98xPo52/zVDfIBd0+WwKWy00wcDMd test"
    static let fingerprint = "SHA256:MbnAMtXWynqq7gbA4EFVMXtHF7VTT0MXNWfQetWSTvY"

    @Test func fingerprintsMatchSSHKeygen() {
        #expect(HostKeyFingerprint.of(publicKeyLine: Self.key) == Self.fingerprint)
        // known_hosts and ssh-keyscan lines have the host first.
        #expect(HostKeyFingerprint.of(publicKeyLine: "[127.0.0.1]:2222 " + Self.key) == Self.fingerprint)
        #expect(HostKeyFingerprint.of(publicKeyLine: "not a key") == nil)
        #expect(HostKeyFingerprint.of(publicKeyLine: "ssh-rsa") == nil)
        #expect(HostKeyFingerprint.of(publicKeyLine: "ssh-rsa !!!notbase64") == nil)
    }

    @Test func knownHostsNames() {
        #expect(HostKeyFingerprint.knownHostsName(host: "h", port: nil) == "h")
        #expect(HostKeyFingerprint.knownHostsName(host: "h", port: 22) == "h")
        #expect(HostKeyFingerprint.knownHostsName(host: "127.0.0.1", port: 2222) == "[127.0.0.1]:2222")
    }

    @Test func readsSSHsChangedKeyReport() {
        let stderr = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
            Someone could be eavesdropping on you right now (man-in-the-middle attack)!
            It is also possible that a host key has just been changed.
            The fingerprint for the ED25519 key sent by the remote host is
            \(Self.fingerprint).
            Please contact your system administrator.
            Add correct host key in /Users/me/my:folder/known_hosts to get rid of this message.
            Offending ED25519 key in /Users/me/my:folder/known_hosts:3
            Host key for [127.0.0.1]:2222 has changed and you have requested strict checking.
            Host key verification failed.
            """
        let c = HostKeyFingerprint.change(inSSHError: stderr)
        #expect(
            c
                == HostKeyFingerprint.Change(
                    keyType: "ED25519", fingerprint: Self.fingerprint, knownHostsFile: "/Users/me/my:folder/known_hosts", line: 3))
        // Without a line number, the file alone.
        let noLine = stderr.replacingOccurrences(of: "known_hosts:3", with: "known_hosts")
        #expect(HostKeyFingerprint.change(inSSHError: noLine)?.knownHostsFile == "/Users/me/my:folder/known_hosts")
        #expect(HostKeyFingerprint.change(inSSHError: noLine)?.line == nil)
        // Other failures, or a report without a fingerprint, are not a change.
        #expect(HostKeyFingerprint.change(inSSHError: "Permission denied (publickey).") == nil)
        #expect(HostKeyFingerprint.change(inSSHError: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!") == nil)
    }
}
