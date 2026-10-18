import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite struct ConnectionMonitorTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test func dropsConnectionsWhenTheNetworkComesBackOrChanges() {
        let drops = Counter()
        let m = ConnectionMonitor(drop: drops.add)
        m.pathChanged(satisfied: true, interfaces: ["en0"])  // the first path is only recorded
        m.pathChanged(satisfied: true, interfaces: ["en0"])
        #expect(drops.value == 0)
        m.pathChanged(satisfied: true, interfaces: ["en1"])  // Wi-Fi to Ethernet
        #expect(drops.value == 1)
        m.pathChanged(satisfied: false, interfaces: [])
        #expect(drops.value == 1)
        m.pathChanged(satisfied: true, interfaces: ["en1"])  // back after a loss
        #expect(drops.value == 2)
    }

    @Test func dropsConnectionsOnWake() async {
        let drops = Counter()
        let m = ConnectionMonitor(drop: drops.add)
        m.systemDidWake()
        m.start()
        m.start()
        #expect(await eventually { drops.value == 1 })
    }
}

@Suite struct HostKeysTests {
    @Test func readsSSHsEffectiveSettings() {
        let e = HostKeys.Effective.parse(
            """
            hostname 10.0.0.5
            user deploy
            port 2200
            proxyjump bastion,ops@gw:22
            userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2
            identityfile ~/.ssh/a
            identityfile ~/.ssh/b
            nokeyvalue
            """)
        #expect(e.hostName == "10.0.0.5" && e.user == "deploy" && e.port == 2200)
        #expect(e.proxyJump == ["bastion", "ops@gw:22"])
        #expect(e.values["identityfile"] == ["~/.ssh/a", "~/.ssh/b"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(e.knownHostsFiles == [home + "/.ssh/known_hosts", home + "/.ssh/known_hosts2"])
        #expect(e.knownHostsName == "[10.0.0.5]:2200")
        #expect(HostKeys.Effective.parse("hostname h\nport 22\nhostkeyalias pinned\n").knownHostsName == "pinned")
        #expect(HostKeys.Effective.parse("hostname h\nport 22\nproxyjump none\n").knownHostsName == "h")
        #expect(HostKeys.Effective.parse("hostname h\nproxyjump none\n").proxyJump.isEmpty)
    }

    @Test func resolvesAHostWithoutConnecting() throws {
        let s = try Scratch("sshG")
        let config = try s.file("config", "Host alias\n  HostName 10.9.8.7\n  User someone\n  Port 2022\n  ProxyJump gw\n")
        let e = try #require(HostKeys.effective(host: "alias", options: ["-F", config.path]))
        #expect(e.hostName == "10.9.8.7" && e.user == "someone" && e.port == 2022 && e.proxyJump == ["gw"])
        let overridden = try #require(HostKeys.effective(host: "alias", user: "me", port: 22, options: ["-F", config.path]))
        #expect(overridden.user == "me" && overridden.port == 22)
        #expect(HostKeys.effective(host: "-oProxyCommand=x") == nil)
        #expect(HostKeys.known(name: "h", in: [s.path("missing").path]).isEmpty)
    }

    @Test func listsAndRemovesKnownKeys() throws {
        let s = try Scratch("knownhosts")
        _ = try Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", s.path("k").path])
        let key = try String(contentsOf: s.path("k.pub"), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        let file = try s.file("known_hosts", "[h]:2222 \(key)\nother \(key)\n")
        let known = HostKeys.known(name: "[h]:2222", in: [file.path])
        #expect(known.map(\.fingerprint) == [HostKeyFingerprint.of(publicKeyLine: key)].compactMap { $0 })
        try HostKeys.remove(name: "[h]:2222", from: file.path)
        #expect(HostKeys.known(name: "[h]:2222", in: [file.path]).isEmpty)
        #expect(HostKeys.known(name: "other", in: [file.path]).count == 1)
        #expect(throws: (any Error).self) { try HostKeys.remove(name: "x", from: s.path("nope/known_hosts").path) }
        // Older ssh-keygen wrote the type last.
        #expect(HostKeys.parseListing("256 SHA256:abc h (RSA)\n", file: "f") == [HostKeys.Known(type: "RSA", fingerprint: "SHA256:abc", file: "f")])
    }

    @Test func findsTheAgent() {
        #expect(HostKeys.agentEnvironment(["SSH_AUTH_SOCK": "/tmp/s"], launchd: { "/other" }).isEmpty)
        #expect(HostKeys.agentEnvironment([:], launchd: { "/launchd/sock" }) == ["SSH_AUTH_SOCK": "/launchd/sock"])
        #expect(HostKeys.agentEnvironment([:], launchd: { nil }).isEmpty)
        #expect(HostKeys.agent(environment: ["SSH_AUTH_SOCK": "/nonexistent/agent.sock"]) == .unavailable)
        _ = HostKeys.launchdAgentSocket()
    }
}
