import Foundation
import PorpoiseCore

/// Discovers file servers on the local network with Bonjour (SMB, AFP, SFTP/SSH, FTP, WebDAV, NFS).
public final class NetworkBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    public static let shared = NetworkBrowser()
    public static let changed = Notification.Name("PorpoiseNetworkChanged")
    public static let url = URL(string: "network:/")!
    private static let resolveTimeout: TimeInterval = 5

    public struct Server: Hashable { let name: String; let url: URL; let kind: String }
    private(set) var servers: [Server] = []
    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []
    private let types: [(String, String, String)] = [
        ("_smb._tcp.", "smb", "Windows / SMB share"), ("_afpovertcp._tcp.", "afp", "Apple file server"),
        ("_sftp-ssh._tcp.", "sftp", "SFTP server"), ("_ssh._tcp.", "sftp", "SSH server"), ("_ftp._tcp.", "ftp", "FTP server"),
        ("_webdav._tcp.", "webdav", "WebDAV server"), ("_webdavs._tcp.", "webdavs", "WebDAV server (secure)"), ("_nfs._tcp.", "nfs", "NFS server"),
    ]

    public func start() {
        guard browsers.isEmpty else { return }
        for (t, _, _) in types {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: t, inDomain: "local.")
            browsers.append(b)
        }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: Self.resolveTimeout)
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.removeAll { $0 === sender } }
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              let t = types.first(where: { $0.0 == sender.type }) else { return }
        let port = sender.port
        let defaultPorts = ["smb": 445, "afp": 548, "sftp": 22, "ftp": 21, "webdav": 80, "webdavs": 443, "nfs": 2049]
        var s = "\(t.1)://\(host)"
        if port > 0, port != defaultPorts[t.1] { s += ":\(port)" }
        if let u = URL(string: s + "/") {
            let server = Server(name: sender.name, url: u, kind: t.2)
            if !servers.contains(server) {
                servers.append(server)
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }

    /// Unresolvable services would otherwise stay in `resolving` forever.
    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        // Only this service's entry: one machine often offers several (SMB and SFTP under one name).
        let kind = types.first { $0.0 == service.type }?.2
        servers.removeAll { $0.name == service.name && $0.kind == kind }
        resolving.removeAll { $0 === service }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Items for the network:/ view.
    public var items: [FileItem] {
        servers.map { s in
            FileItem(url: s.url, name: "\(s.name) (\(s.url.scheme?.uppercased() ?? ""))", isDirectory: true, contentType: "public.folder")
        }
    }
}
