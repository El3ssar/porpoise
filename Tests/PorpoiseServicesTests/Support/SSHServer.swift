import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A real OpenSSH server on 127.0.0.1, run as the current user with its own host key, client key and known_hosts,
/// all in a scratch folder. Its sessions get a scratch HOME, so neither side reads or writes anything in ~/.ssh,
/// and the login shell's own startup files are the scratch home's (none).
final class SSHServer: @unchecked Sendable {
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") }

    /// The one server of the running suite (see `Trait.sshServer`).
    @TaskLocal static var current: SSHServer?

    let scratch: Scratch
    let port: Int
    /// The remote user's HOME; tests work in folders made inside it.
    let home: URL
    /// Holds the shared connection's socket. Socket paths are limited to 104 bytes, more than a scratch folder's
    /// path allows, so this is a short folder directly in $TMPDIR, removed by `stop()`.
    let controlDir: URL
    private let pidFile: URL
    private let log: URL
    private var providers: [SSHProvider] = []
    private let lock = NSLock()

    init() throws {
        scratch = try Scratch("sshd")
        home = try scratch.folder("home")
        pidFile = scratch.path("sshd.pid")
        log = scratch.path("sshd.log")
        controlDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pssh-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        port = try Self.freePort()

        try Self.keygen(scratch.path("host_key"))
        try Self.keygen(scratch.path("client_key"))
        try FileManager.default.copyItem(at: scratch.path("client_key.pub"), to: scratch.path("authorized_keys"))
        // Trusted up front, so the client checks the key strictly and never needs to record one.
        let hostKey = (scratch.read("host_key.pub") ?? "").split(separator: " ").prefix(2).joined(separator: " ")
        try scratch.file("known_hosts", "[127.0.0.1]:\(port) \(hostKey)\n")
        try scratch.file(
            "sshd_config",
            """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(scratch.path("host_key").path)
            AuthorizedKeysFile \(scratch.path("authorized_keys").path)
            PidFile \(pidFile.path)
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            UsePAM no
            StrictModes no
            Subsystem sftp internal-sftp
            SetEnv HOME=\(home.path)

            """)

        // sshd forks into the background once it listens; the child writes the pid file right after.
        let r = try Shell.run("/usr/sbin/sshd", ["-f", scratch.path("sshd_config").path, "-E", log.path])
        guard r.status == 0 else { throw Failure("sshd did not start: \(r.err) \(scratch.read("sshd.log") ?? "")") }
        let deadline = Date().addingTimeInterval(5)
        while serverPID == nil && Date() < deadline { usleep(20_000) }
        guard serverPID != nil else { throw Failure("sshd wrote no pid file: \(scratch.read("sshd.log") ?? "")") }
    }

    private var serverPID: pid_t? { scratch.read("sshd.pid").flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }

    /// Stops the server (sessions still open end with it) and removes the socket folder.
    func stop() {
        // Shared connections outlive the listener: end them first, or their sessions linger for minutes.
        lock.lock(); let all = providers; lock.unlock()
        all.forEach { $0.disconnect() }
        if let pid = serverPID {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(3)
            while kill(pid, 0) == 0 && Date() < deadline { usleep(20_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: controlDir)
    }

    /// A provider that connects with this server's keys only: no ~/.ssh/config, agent, user keys or known_hosts.
    func provider() -> SSHProvider {
        let p = SSHProvider(
            url: url("/"),
            isolation: .init(
                options: [
                    "-F", "/dev/null", "-i", scratch.path("client_key").path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                    "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\(scratch.path("known_hosts").path)",
                    "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes",
                ], controlDir: controlDir))
        lock.lock(); providers.append(p); lock.unlock()
        return p
    }

    /// sftp:// URL of a path on this server.
    func url(_ path: String, isDirectory: Bool = false) -> URL {
        var c = URLComponents()
        c.scheme = "sftp"
        c.user = NSUserName()
        c.host = "127.0.0.1"
        c.port = port
        c.path = path
        let u = c.url!
        return isDirectory ? u.appendingPathComponent("", isDirectory: true) : u
    }

    func url(_ local: URL) -> URL { url(local.path) }

    /// A fresh, empty folder in the remote home for one test.
    func folder(_ name: String = #function) throws -> URL {
        let safe = name.filter { $0.isLetter || $0.isNumber }
        let u = home.appendingPathComponent(safe)
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// How many logins the server has accepted.
    var logins: Int { (scratch.read("sshd.log") ?? "").components(separatedBy: "Accepted publickey").count - 1 }

    private static func keygen(_ path: URL) throws {
        let r = try Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "porpoise-test", "-f", path.path])
        guard r.status == 0 else { throw Failure("ssh-keygen failed: \(r.err)") }
    }

    /// A port nobody listens on right now (the kernel's pick for a socket bound to port 0).
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { throw Failure("no free port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

/// Runs a suite with one `SSHServer`, started before its first test and stopped after its last, also when tests fail.
struct SSHServerTrait: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let server = try SSHServer()
        defer { server.stop() }
        try await SSHServer.$current.withValue(server) { try await function() }
    }
}

extension Trait where Self == SSHServerTrait {
    static var sshServer: Self { Self() }
}
