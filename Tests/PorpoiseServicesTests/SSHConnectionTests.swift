import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// What the connection manager adds to SSH, against a real sshd on 127.0.0.1 (see `SSHServer`): a saved profile's
/// jump host, reconnecting after the connection is lost, and accepting a server's changed key after seeing its
/// fingerprint.
@Suite(.serialized, .enabled(if: SSHServer.isAvailable, "needs /usr/sbin/sshd"), .sshServer)
struct SSHConnectionTests {
    let server = SSHServer.current!
    let fm = FileManager.default
    /// Holds the test's askpass script.
    let scratch: Scratch

    init() throws { scratch = try Scratch("sshconnection") }

    // MARK: Jump hosts

    @Test func aProfilesJumpHostIsUsed() throws {
        let dir = try server.folder()
        try Data("hi".utf8).write(to: dir.appendingPathComponent("through-jump.txt"))
        let profiles = ConnectionProfiles(storeURL: nil)
        // The server is its own jump host, under another name (ssh refuses a jump to the host itself): one login to
        // reach it, one more through it.
        let jump = "\(NSUserName())@localhost:\(server.port)"
        let trusted = try String(contentsOf: server.knownHosts, encoding: .utf8)
        defer { try? trusted.write(to: server.knownHosts, atomically: true, encoding: .utf8) }
        let key = trusted.split(separator: " ").dropFirst().prefix(2).joined(separator: " ")
        try (trusted + "[localhost]:\(server.port) \(key)\n").write(to: server.knownHosts, atomically: true, encoding: .utf8)
        profiles.save(ConnectionProfile(name: "via jump", kind: .sftp, host: "127.0.0.1", port: server.port, user: NSUserName(), jumpHosts: [jump]))
        #expect(profiles.sshOptions(for: server.url("/")) == ["-J", jump])

        let before = server.logins
        let p = server.provider(profiles: profiles, options: ["-F", try server.clientConfig().path])
        let items = try p.list(server.url(dir.path, isDirectory: true))

        #expect(items.map(\.name) == ["through-jump.txt"])
        #expect(server.logins - before == 2)
    }

    @Test func aProfilesKeyIsTheOnlyOneOffered() throws {
        let profiles = ConnectionProfiles(storeURL: nil)
        profiles.save(
            ConnectionProfile(name: "k", kind: .sftp, host: "127.0.0.1", port: server.port, user: NSUserName(), identityFile: server.clientKey.path))
        // No key in the isolation options: the profile's is the one that logs in.
        let p = server.provider(
            profiles: profiles,
            options: [
                "-F", "/dev/null", "-o", "IdentityAgent=none", "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\(server.knownHosts.path)",
                "-o", "StrictHostKeyChecking=yes",
            ])
        _ = try p.list(server.url(try server.folder().path, isDirectory: true))
        #expect(ConnectionProfiles.sshOptions(for: profiles.profiles[0]) == ["-i", server.clientKey.path, "-o", "IdentitiesOnly=yes"])
    }

    @Test func logsInWithTheAgentsKey() throws {
        let sock = server.controlDir.appendingPathComponent("agent").path
        let started = try Shell.run("/usr/bin/ssh-agent", ["-a", sock])
        #expect(started.status == 0)
        let pid = String(decoding: started.out, as: UTF8.self).components(separatedBy: "SSH_AGENT_PID=").dropFirst().first?
            .prefix { $0.isNumber }
        defer { if let pid, let n = Int32(pid) { kill(n, SIGTERM) } }
        let env = ["SSH_AUTH_SOCK": sock]
        #expect(HostKeys.agent(environment: env) == .empty)
        #expect(try Shell.run("/usr/bin/ssh-add", [server.clientKey.path], env: env).status == 0)
        #expect(HostKeys.agent(environment: env) == .keys(1))

        // No key file given: the agent's key logs in.
        server.provider().disconnect()
        let p = server.provider(options: [
            "-F", "/dev/null", "-o", "IdentityAgent=\(sock)", "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\(server.knownHosts.path)",
            "-o", "StrictHostKeyChecking=yes",
        ])
        _ = try p.list(server.url(try server.folder().path, isDirectory: true))
        p.disconnect()
    }

    // MARK: Reconnect

    @Test func aCommandCutOffMidwayRunsAgainOnANewConnection() throws {
        let dir = try server.folder()
        let marker = dir.appendingPathComponent("cut-once")
        var waits: [TimeInterval] = []
        let p = server.provider(reconnect: ReconnectPolicy(delays: [0.2, 0.2]))
        p.wait = {
            waits.append($0); Thread.sleep(forTimeInterval: $0)
        }
        _ = try p.list(server.url(dir.path, isDirectory: true))  // connected once

        // The first run ends its own connection (as a network loss would) before answering; the second answers.
        let q = RemoteParsing.quote(marker.path)
        let out = try p.exec("if [ ! -e \(q) ]; then touch \(q); kill -9 $PPID; sleep 1; fi; echo answered")

        #expect(String(decoding: out, as: UTF8.self) == "answered\n")
        #expect(waits == [0.2])
    }

    @Test func aRenameCutOffMidwayIsNotRunTwice() throws {
        let dir = try server.folder()
        let p = server.provider(reconnect: ReconnectPolicy(delays: [0]))
        p.wait = { _ in }
        _ = try p.list(server.url(dir.path, isDirectory: true))
        let marker = RemoteParsing.quote(dir.appendingPathComponent("ran").path)
        // A command that mustn't run twice fails with the lost connection instead of being run again.
        #expect(throws: (any Error).self) {
            try p.exec(idempotent: false, "echo x >> \(marker); kill -9 $PPID; sleep 1")
        }
        #expect((try? String(contentsOf: dir.appendingPathComponent("ran"), encoding: .utf8)) == "x\n")
    }

    @Test func aServerThatWentAwayIsReachedAgainWhenItsBack() throws {
        let dir = try server.folder()
        try Data("x".utf8).write(to: dir.appendingPathComponent("still-here.txt"))
        let p = server.provider(reconnect: ReconnectPolicy(delays: [0.1, 0.1, 0.1]))
        _ = try p.list(server.url(dir.path, isDirectory: true))

        server.killAbruptly()
        var waits = 0
        p.wait = { _ in
            waits += 1
            // Back on the second try: the first finds nobody listening.
            if waits == 2 { try? self.server.start() }
        }
        let items = try p.list(server.url(dir.path, isDirectory: true))

        #expect(items.map(\.name) == ["still-here.txt"])
        #expect(waits == 2)
    }

    @Test func aRetiredConnectionLetsItsCommandFinishAndTheNextOneConnectsAfresh() async throws {
        let dir = try server.folder()
        let p = server.provider()
        _ = try p.list(server.url(dir.path, isDirectory: true))
        let before = server.logins
        let started = dir.appendingPathComponent("started"), release = dir.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        // A command still running on the old connection when it is retired finishes there.
        nonisolated(unsafe) var running: Data?
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            running = try? p.exec(
                "touch \(RemoteParsing.quote(started.path)); while [ ! -e \(RemoteParsing.quote(release.path)) ]; do sleep 0.01; done; echo finished")
            done.signal()
        }
        try #require(await poll { fm.fileExists(atPath: started.path) })
        RemoteFS.use(p, for: server.url("/"))
        defer { RemoteFS.use(nil, for: server.url("/")) }
        RemoteFS.retireSharedConnections()
        _ = try p.list(server.url(dir.path, isDirectory: true))
        #expect(server.logins == before + 1)
        try Data().write(to: release)
        #expect(await offThePool { done.wait(timeout: .now() + eventualTimeout) == .success })
        #expect(running.map { String(decoding: $0, as: UTF8.self) } == "finished\n")
    }

    @Test func aFirstConnectionThatFailsIsNotRetried() throws {
        let p = SSHProvider(
            url: URL(string: "sftp://127.0.0.1:1/")!,
            isolation: .init(options: ["-F", "/dev/null", "-o", "BatchMode=yes"], controlDir: server.controlDir),
            profiles: ConnectionProfiles(storeURL: nil),
            reconnect: ReconnectPolicy(delays: [5]))
        var waited = false
        p.wait = { _ in waited = true }
        #expect(throws: (any Error).self) { try p.list(URL(string: "sftp://127.0.0.1:1/")!) }
        #expect(!waited)
    }

    @Test func waitingStopsWhenTheTransferIsCancelled() {
        var cancelled = false
        let control = Shell.TransferControl(isPaused: { false }, isCancelled: { cancelled })
        var now = Date(timeIntervalSince1970: 1000), sleeps: [TimeInterval] = []
        func sleep(_ seconds: TimeInterval) { sleeps.append(seconds); now += seconds }
        Shell.withTransferControl(control) {
            cancelled = true
            SSHProvider.waitUnlessCancelled(10, now: { now }, sleep: sleep)
        }
        #expect(sleeps.isEmpty)
        // Cancellation after a step also prevents every remaining step, regardless of host scheduling.
        cancelled = false
        Shell.withTransferControl(control) {
            SSHProvider.waitUnlessCancelled(10, now: { now }) { seconds in
                sleep(seconds)
                cancelled = true
            }
        }
        #expect(sleeps == [0.1])
        let short = Date()
        SSHProvider.waitUnlessCancelled(0.05)
        #expect(Date().timeIntervalSince(short) >= 0.05)
    }

    // MARK: Host keys

    /// An askpass that answers ssh's host-key question with the fingerprint the app passes it.
    private func answeringAskPass() throws -> String {
        // ssh asks again after an answer that isn't the key's fingerprint: then the answer is no (as the app's helper does).
        let f = try scratch.file(
            "askpass",
            """
            #!/bin/sh
            case "$1" in *"Please type"*) echo no; exit 0;; esac
            printf '%s\\n' "$\(HostKeyFingerprint.answerVariable)"

            """)
        chmod(f.path, 0o755)
        return f.path
    }

    /// Replaces the trusted key with another one, as if the server's key had changed.
    private func trustAnotherKey() throws -> String {
        let original = try String(contentsOf: server.knownHosts, encoding: .utf8)
        let s = try Scratch("otherkey")
        _ = try Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", s.path("k").path])
        let other = try String(contentsOf: s.path("k.pub"), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:\(server.port) \(other)\n".write(to: server.knownHosts, atomically: true, encoding: .utf8)
        return original
    }

    @MainActor @Test func aChangedHostKeyIsShownAndReplacedOnlyWhenAccepted() throws {
        // A shared connection from an earlier test would skip the key check.
        server.provider().disconnect()
        let original = try trustAnotherKey()
        defer { try? original.write(to: server.knownHosts, atomically: true, encoding: .utf8) }
        let config = try server.clientConfig(batch: false).path
        let dir = try server.folder()
        let realFingerprint = HostKeyFingerprint.of(publicKeyLine: original)

        // Refused: nothing changes.
        nonisolated(unsafe) var shown: [(String, HostKeyFingerprint.Change)] = []
        RemoteFS.confirmHostKeyChange = {
            shown.append(($0, $1)); return false
        }
        defer { RemoteFS.confirmHostKeyChange = { _, _ in false } }
        let refusing = server.provider(askPass: try answeringAskPass(), options: ["-F", config])
        #expect(throws: (any Error).self) { try refusing.list(server.url(dir.path, isDirectory: true)) }
        #expect(shown.count == 1)
        #expect(shown.first?.0 == "[127.0.0.1]:\(server.port)")
        #expect(shown.first?.1.fingerprint == realFingerprint)
        #expect(shown.first?.1.knownHostsFile == server.knownHosts.path)
        #expect(HostKeys.known(name: "[127.0.0.1]:\(server.port)", in: [server.knownHosts.path]).map(\.fingerprint) != [realFingerprint])

        // Accepted: the old key goes, and the server's (the fingerprint shown) is recorded.
        RemoteFS.confirmHostKeyChange = { _, _ in true }
        let accepting = server.provider(askPass: try answeringAskPass(), options: ["-F", config])
        _ = try accepting.list(server.url(dir.path, isDirectory: true))
        #expect(HostKeys.known(name: "[127.0.0.1]:\(server.port)", in: [server.knownHosts.path]).map(\.fingerprint) == [realFingerprint])
        // And from now on it connects without asking.
        _ = try server.provider(options: ["-F", try server.clientConfig().path]).list(server.url(dir.path, isDirectory: true))
    }

    @Test func sshAcceptsANewKeyOnlyWithTheFingerprintTheUserSaw() throws {
        // The approval relies on ssh comparing the answer with the key it was sent: a different one is refused.
        let original = try String(contentsOf: server.knownHosts, encoding: .utf8)
        defer { try? original.write(to: server.knownHosts, atomically: true, encoding: .utf8) }
        try "".write(to: server.knownHosts, atomically: true, encoding: .utf8)
        let ask = try answeringAskPass()
        func connect(answer: String) throws -> Shell.Result {
            try Shell.run(
                "/usr/bin/ssh",
                [
                    "-F", try server.clientConfig(batch: false).path, "-o", "StrictHostKeyChecking=ask", "-p", String(server.port),
                    "--", "\(NSUserName())@127.0.0.1", "true",
                ], env: ["SSH_ASKPASS": ask, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", HostKeyFingerprint.answerVariable: answer],
                timeout: 20)
        }
        #expect(try connect(answer: HostKeyFingerprintTestsData.otherFingerprint).status != 0)
        #expect(try connect(answer: HostKeyFingerprint.of(publicKeyLine: original)!).status == 0)
    }

    @Test func hostKeysListsWhatSSHKnows() throws {
        let fp = HostKeyFingerprint.of(publicKeyLine: try String(contentsOf: server.knownHosts, encoding: .utf8))
        let known = HostKeys.known(host: "127.0.0.1", port: server.port, options: ["-F", try server.clientConfig().path])
        #expect(known.map(\.fingerprint) == [fp].compactMap { $0 })
        #expect(known.first?.type == "ED25519", "\(known)")
        #expect(known.first?.file == server.knownHosts.path, "\(known)")
        #expect(HostKeys.known(host: "-x").isEmpty)
    }
}

enum HostKeyFingerprintTestsData {
    static let otherFingerprint = "SHA256:MbnAMtXWynqq7gbA4EFVMXtHF7VTT0MXNWfQetWSTvY"
}
