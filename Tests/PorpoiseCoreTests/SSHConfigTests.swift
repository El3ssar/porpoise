import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

@Suite struct SSHConfigTests {
    static let sample = """
        # global defaults come before any Host
        ServerAliveInterval 60

        Host web prod-web
          HostName web.example.com
          User deploy
          Port 2222
          IdentityFile ~/.ssh/deploy_ed25519

        Host db
          HostName=10.0.0.5
          ProxyJump bastion,user@jump2:2200

        Host bastion
          HostName bastion.example.com
          User ops

        Host *.internal !secret.internal
          User internal
          ProxyJump bastion

        Match host weird
          User nobody

        Host *
          User fallback
          IdentityFile ~/.ssh/id_ed25519
        """

    @Test func listsConcreteAliasesInOrder() {
        let c = SSHConfig(parsing: Self.sample)
        #expect(c.aliases == ["web", "prod-web", "db", "bastion"])
    }

    @Test func firstValueWinsAndWildcardsFillTheRest() {
        let c = SSHConfig(parsing: Self.sample)
        let web = c.resolve("web")
        #expect(web.hostName == "web.example.com" && web.user == "deploy" && web.port == 2222)
        // IdentityFile accumulates, in file order, as in ssh.
        #expect(web.identityFiles == ["~/.ssh/deploy_ed25519", "~/.ssh/id_ed25519"])
        #expect(web.proxyJump.isEmpty)
        let db = c.resolve("db")
        #expect(db.hostName == "10.0.0.5")
        #expect(db.user == "fallback")
        #expect(db.proxyJump == ["bastion", "user@jump2:2200"])
    }

    @Test func negatedPatternsAndMatchBlocks() {
        let c = SSHConfig(parsing: Self.sample)
        #expect(c.resolve("a.internal").user == "internal")
        #expect(c.resolve("a.internal").proxyJump == ["bastion"])
        #expect(c.resolve("secret.internal").user == "fallback")
        // Match blocks are never applied: their conditions need a connection.
        #expect(c.resolve("weird").user == "fallback")
        // An unknown name is its own host name.
        #expect(c.resolve("other").hostName == "other")
    }

    @Test func proxyJumpNoneAndProxyCommand() {
        let c = SSHConfig(
            parsing: """
                Host a
                  ProxyJump none
                  ProxyCommand ssh -W %h:%p gw
                  HostName %h.lan
                Host *
                  ProxyJump gw
                """)
        let a = c.resolve("a")
        #expect(a.proxyJump.isEmpty)
        #expect(a.proxyCommand == "ssh -W %h:%p gw")
        #expect(a.hostName == "a.lan")
    }

    @Test func includeAddsFilesWhereItStands() {
        let files = ["conf.d/work": "Host work\n  HostName work.example.com\n", "extra": "User from-include\nHost late\n"]
        let c = SSHConfig(
            parsing: """
                Include conf.d/work
                Host first
                  Include extra
                """
        ) { path in files[path].map { [$0] } ?? [] }
        #expect(c.aliases == ["work", "first", "late"])
        #expect(c.resolve("work").hostName == "work.example.com")
        // The included file's options before its own Host belong to the block it was included in.
        #expect(c.resolve("first").user == "from-include")
    }

    @Test func includeRecursionStops() {
        let c = SSHConfig(parsing: "Include self\nHost x\n") { _ in ["Include self\nHost y\n"] }
        #expect(c.aliases.contains("x") && c.aliases.contains("y"))
    }

    @Test func loadsFromDiskWithWildcardIncludes() throws {
        let s = try Scratch("sshconfig")
        _ = try s.folder("conf.d")
        try s.file("conf.d/b.conf", "Host b\n")
        try s.file("conf.d/a.conf", "Host a\n")
        try s.file("conf.d/skip.txt", "Host skipped\n")
        try s.file("config", "Include conf.d/*.conf\nInclude \(s.path("abs").path)\nHost z\n")
        try s.file("abs", "Host abs\n")
        let c = SSHConfig.load(s.path("config"))
        #expect(c.aliases == ["a", "b", "abs", "z"])
        #expect(SSHConfig.load(s.path("missing")).aliases.isEmpty)
        #expect(SSHConfig.includedFiles("~/x", sshDir: s.url).first?.path.hasSuffix("/x") == true)
    }

    private func pair(_ line: String) -> [String]? { SSHConfig.split(line).map { [$0.0, $0.1] } }

    @Test func lineSyntax() {
        #expect(pair("  Port=22") == ["port", "22"])
        #expect(pair("Port = 22") == ["port", "22"])
        #expect(pair("\tUser\tme ") == ["user", "me"])
        #expect(pair("Compression") == ["compression", ""])
        #expect(SSHConfig.split("# comment") == nil)
        #expect(SSHConfig.split("   ") == nil)
        #expect(SSHConfig.words("a \"b c\" d") == ["a", "b c", "d"])
        #expect(SSHConfig.words("\"\"") == [""])
    }

    @Test func globPatterns() {
        #expect(SSHConfig.glob("*", "anything"))
        #expect(SSHConfig.glob("web?", "web1") && !SSHConfig.glob("web?", "web12"))
        #expect(SSHConfig.glob("*.example.com", "a.b.example.com"))
        #expect(!SSHConfig.glob("*.example.com", "example.com"))
        #expect(SSHConfig.glob("a*b*c", "aXXbYYc") && !SSHConfig.glob("a*b*c", "aXXbYY"))
        #expect(SSHConfig.Block(patterns: ["WEB"], options: []).matches("web"))
        #expect(!SSHConfig.Block(patterns: ["!*"], options: []).matches("x"))
        #expect(SSHConfig(parsing: Self.sample) == SSHConfig(parsing: Self.sample))
    }
}
