import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.serialized) struct SSHCorrectnessTests {
    @Test(arguments: ["pinned", "test-alias"])
    func failedApprovalPreservesTrustAndUsesEffectiveAlias(_ identity: String) throws {
        let scratch = try Scratch()
        let key = scratch.path("key")
        _ = try Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path])
        let publicKey = try String(contentsOf: scratch.path("key.pub"), encoding: .utf8)
        let original = "\(identity) \(publicKey)"
        let known = try scratch.file("known_hosts", original)
        let config = try scratch.file(
            "config", "Host test-alias\n HostName test-alias\n HostKeyAlias \(identity)\n UserKnownHostsFile \(known.path)\n")
        let fake = try scratch.file(
            "ssh",
            """
            #!/bin/sh
            if [ -n "$SSH_ASKPASS_ACCEPTED_FINGERPRINT" ]; then exit 255; fi
            cat >&2 <<'ERROR'
            REMOTE HOST IDENTIFICATION HAS CHANGED
            The fingerprint for the ED25519 key sent by the remote host is
            SHA256:replacement.
            Offending ED25519 key in \(known.path):1
            ERROR
            exit 255

            """)
        chmod(fake.path, 0o700)
        var shown: String?
        RemoteFS.confirmHostKeyChange = { name, _ in
            shown = name; return true
        }
        defer { RemoteFS.confirmHostKeyChange = { _, _ in false } }
        let provider = SSHProvider(
            url: URL(string: "sftp://test-alias/")!,
            isolation: .init(options: ["-F", config.path], controlDir: scratch.url, askPass: "/usr/bin/false", executable: fake.path))
        #expect(throws: (any Error).self) { try provider.exec("true") }
        #expect(shown == identity)
        #expect(try String(contentsOf: known, encoding: .utf8) == original)
    }

    @Test(arguments: [0, 3], [false, true])
    func successfulApprovalPreservesLinkedTrustAndCommandStatus(_ status: Int, _ linked: Bool) throws {
        let scratch = try Scratch()
        for name in ["old", "new"] {
            _ = try Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", scratch.path(name).path])
        }
        let oldKey = try String(contentsOf: scratch.path("old.pub"), encoding: .utf8)
        let newKey = try String(contentsOf: scratch.path("new.pub"), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        let fingerprint = try #require(HostKeyFingerprint.of(publicKeyLine: newKey))
        let real = try scratch.file("trust/known_hosts", "pinned \(oldKey)")
        chmod(real.path, 0o640)
        let known = linked ? scratch.path("known_hosts") : real
        if linked { try FileManager.default.createSymbolicLink(at: known, withDestinationURL: real) }
        let config = try scratch.file("config", "Host test-alias\n HostName test-alias\n HostKeyAlias pinned\n")
        let fake = try scratch.file(
            "ssh",
            """
            #!/bin/sh
            if [ -n "$SSH_ASKPASS_ACCEPTED_FINGERPRINT" ]; then
              for arg do
                case "$arg" in UserKnownHostsFile=*) file="${arg#UserKnownHostsFile=}"; break;; esac
              done
              printf '%s\\n' 'pinned \(newKey)' > "$file"
              exit \(status)
            fi
            cat >&2 <<'ERROR'
            REMOTE HOST IDENTIFICATION HAS CHANGED
            The fingerprint for the ED25519 key sent by the remote host is
            \(fingerprint).
            Offending ED25519 key in \(known.path):1
            ERROR
            exit 255

            """)
        chmod(fake.path, 0o700)
        RemoteFS.confirmHostKeyChange = { _, _ in true }
        defer { RemoteFS.confirmHostKeyChange = { _, _ in false } }
        let provider = SSHProvider(
            url: URL(string: "sftp://test-alias/")!,
            isolation: .init(options: ["-F", config.path], controlDir: scratch.url, askPass: "/usr/bin/false", executable: fake.path))
        if status == 0 { try provider.exec("true") } else { #expect(throws: (any Error).self) { try provider.exec("false") } }
        #expect(HostKeys.known(name: "pinned", in: [real.path]).map(\.fingerprint) == [fingerprint])
        if linked { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: known.path) == real.path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: real.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.deletingLastPathComponent().path) == ["known_hosts"])
    }

}
