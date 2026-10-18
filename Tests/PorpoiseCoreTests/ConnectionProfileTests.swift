import Foundation
import Testing

@testable import PorpoiseCore

@Suite struct ConnectionProfileTests {
    @Test func sftpURLs() {
        var p = ConnectionProfile(name: "Web", kind: .sftp, host: "web.example.com", user: "deploy")
        #expect(p.url?.absoluteString == "sftp://deploy@web.example.com/~/")
        p.path = "sites/a b"
        #expect(p.url?.absoluteString == "sftp://deploy@web.example.com/~/sites/a%20b")
        p.path = "/srv/www"
        p.port = 2222
        #expect(p.url?.absoluteString == "sftp://deploy@web.example.com:2222/srv/www")
        p.port = 22
        #expect(p.url?.absoluteString == "sftp://deploy@web.example.com/srv/www")
        #expect(p.problem == nil)
    }

    @Test func profilesFromSSHConfigUseTheAlias() {
        let host = SSHConfig.Host(
            alias: "db", hostName: "10.0.0.5", user: "u", port: 2200, proxyJump: ["bastion"], identityFiles: [], proxyCommand: nil)
        var p = ConnectionProfile(sshHost: host)
        #expect(p.kind == .sftp && p.name == "db" && p.sshAlias == "db")
        // ssh reads the alias's HostName, User, Port and ProxyJump itself.
        #expect(p.url?.absoluteString == "sftp://db/~/")
        // A port set on top of an alias is passed even when it's 22, since the config may say otherwise.
        p.port = 22
        #expect(p.url?.absoluteString == "sftp://db:22/~/")
    }

    @Test func otherKinds() {
        let ftp = ConnectionProfile(name: "F", kind: .ftps, host: "files.example.com", port: 990, user: "me", path: "pub")
        #expect(ftp.url?.absoluteString == "ftps://me@files.example.com:990/pub")
        let smb = ConnectionProfile(name: "NAS", kind: .smb, host: "nas.local", user: "me", path: "Public/Photos")
        #expect(smb.url?.absoluteString == "smb://me@nas.local/Public/Photos")
        let ftpRoot = ConnectionProfile(name: "F", kind: .ftp, host: "h")
        #expect(ftpRoot.url?.absoluteString == "ftp://h/")
    }

    @Test func s3URLsUseTheS3LocationForm() {
        let id = UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!
        var p = ConnectionProfile(
            id: id, name: "Backups", kind: .s3, path: "daily/2026", bucket: "my-backups", endpoint: "http://127.0.0.1:9000",
            region: "eu-west-1", accessKeyID: "AKIAEXAMPLE")
        #expect(
            p.url?.absoluteString
                == "s3://my-backups/daily/2026/?endpoint=http%3A%2F%2F127.0.0.1%3A9000&region=eu-west-1&account=0a1b2c3d-0000-4000-8000-000000000001")
        p.path = ""
        p.region = nil
        #expect(p.url?.path == "/")
        #expect(p.url?.query?.contains("region=us-east-1") == true)
        #expect(p.covers(p.url!))
        #expect(!p.covers(URL(string: "s3://my-backups/?account=other")!))
        #expect(p.address == "my-backups on 127.0.0.1")
        // The access key ID is kept; there is no field for the secret.
        let json = String(decoding: try! JSONEncoder().encode(p), as: UTF8.self)
        #expect(json.contains("AKIAEXAMPLE") && !json.lowercased().contains("secret") && !json.lowercased().contains("password"))
    }

    @Test(arguments: [
        (ConnectionProfile(name: " ", kind: .sftp, host: "h"), "name"),
        (ConnectionProfile(name: "a", kind: .sftp, host: ""), "server"),
        (ConnectionProfile(name: "a", kind: .sftp, host: "-oProxyCommand=x"), "“-”"),
        (ConnectionProfile(name: "a", kind: .sftp, host: "h", user: "-x"), "“-”"),
        (ConnectionProfile(name: "a", kind: .sftp, host: "a b"), "spaces"),
        (ConnectionProfile(name: "a", kind: .sftp, host: "h", port: 70000), "port"),
        (ConnectionProfile(name: "a", kind: .sftp, host: "h", jumpHosts: ["-J"]), "jump"),
        (ConnectionProfile(name: "a", kind: .sftp, host: "h", jumpHosts: ["a,b"]), "jump"),
        (ConnectionProfile(name: "a", kind: .smb, host: "h"), "share"),
        (ConnectionProfile(name: "a", kind: .s3, bucket: "No", endpoint: "https://x"), "bucket"),
        (ConnectionProfile(name: "a", kind: .s3, bucket: "-bucket", endpoint: "https://x"), "bucket"),
        (ConnectionProfile(name: "a", kind: .s3, bucket: "bucket", endpoint: "x"), "endpoint"),
        (ConnectionProfile(name: "a", kind: .s3, bucket: "bucket", endpoint: "http://s3.example.com"), "https"),
        (ConnectionProfile(name: "a", kind: .s3, bucket: "bucket", endpoint: "ftp://s3.example.com"), "https"),
        (ConnectionProfile(name: "a", kind: .s3, bucket: "bucket", endpoint: "https://s3.example.com/bucket"), "address"),
        (ConnectionProfile(name: "a", kind: .s3, bucket: "bucket", endpoint: "https://s3.example.com", region: "eu west"), "region"),
    ])
    func problems(_ p: ConnectionProfile, _ word: String) {
        #expect(p.problem?.contains(word) == true, "\(p.problem ?? "nil")")
        #expect(p.url == nil)
    }

    @Test func coversItsServerOnly() {
        let p = ConnectionProfile(name: "Web", kind: .sftp, host: "Web.Example.com", user: "deploy")
        #expect(p.covers(URL(string: "sftp://deploy@web.example.com/srv")!))
        #expect(p.covers(URL(string: "ssh://deploy@web.example.com:22/")!))
        #expect(!p.covers(URL(string: "sftp://other@web.example.com/")!))
        #expect(!p.covers(URL(string: "sftp://deploy@web.example.com:2222/")!))
        #expect(!p.covers(URL(string: "ftp://deploy@web.example.com/")!))
        #expect(!p.covers(URL(string: "sftp://deploy@other.example.com/")!))
        #expect(!p.covers(URL(string: "/local")!))
        let anyone = ConnectionProfile(name: "x", kind: .ftp, host: "h", port: 21)
        #expect(anyone.covers(URL(string: "ftp://h/")!))
    }

    @Test func addressesAndKinds() {
        let p = ConnectionProfile(name: "x", kind: .sftp, host: "h", port: 2222, user: "me", jumpHosts: ["a", "b"])
        #expect(p.address == "me@h:2222 via a → b")
        #expect(ConnectionProfile.Kind.allCases.map(\.title) == ["SFTP", "FTP", "FTPS", "Windows (SMB)", "S3-compatible"])
        #expect(ConnectionProfile.Kind.allCases.map(\.defaultPort) == [22, 21, 21, 445, nil])
        #expect(ConnectionProfile.Kind.allCases.filter(\.storesSecret) == [.ftp, .ftps, .smb, .s3])
    }

    @Test func capabilityReports() {
        for kind in ConnectionProfile.Kind.allCases {
            let report = ConnectionCapability.report(for: kind)
            #expect(report.count >= 5)
            #expect(report.contains { $0.name.hasPrefix("Reconnect") })
        }
        #expect(ConnectionCapability.report(for: .ftp).contains { $0.name == "Encrypted connection" && $0.support != .yes })
        #expect(ConnectionCapability.report(for: .ftps).contains { $0.name == "Encrypted connection" && $0.support == .yes })
        #expect(ConnectionCapability.report(for: .s3).contains { $0.support == .no })
    }
}
