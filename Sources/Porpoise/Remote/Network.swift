import AppKit
import CryptoKit
import NetFS
import PorpoiseCore

// MARK: - Opening remote files

/// Opens a remote file: downloads it to a cache, opens it, and uploads it again when the app saves changes
/// (KIO does the same for remote files opened in local applications).
enum RemoteOpener {
    private static var watchers: [String: DispatchSourceFileSystemObject] = [:]

    /// Upload is delayed this long after the last change, so a burst of writes from one save uploads once.
    private static let uploadDelay: TimeInterval = 0.6
    /// Uploads run one at a time, so an older save can never land on the server after a newer one.
    private static let uploadQueue = DispatchQueue(label: "dolphin.remote-upload")

    /// Mirror of the remote folder inside the cache. "." and ".." components are dropped so a crafted
    /// URL (sftp://host/../../x) can't point outside the cache: the file there is replaced on download.
    static func cacheFolder(for remote: URL) -> URL {
        var folder = RemoteFS.cacheRoot.appendingPathComponent(remote.scheme ?? "x").appendingPathComponent(remote.host ?? "h")
        for c in remote.deletingLastPathComponent().pathComponents where RemoteParsing.isSafeName(c) {
            folder.appendPathComponent(c)
        }
        return folder
    }

    static func open(_ item: FileItem) {
        guard let p = RemoteFS.provider(for: item.url), RemoteParsing.isSafeName(item.url.lastPathComponent) else { return }
        let folder = cacheFolder(for: item.url)
        StatusCenter.post("Downloading “\(item.name)”…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let local = folder.appendingPathComponent(item.url.lastPathComponent)
                try? FileManager.default.removeItem(at: local)
                let got = try p.download(item.url, into: folder)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(got)
                    watch(got, remote: item.url, provider: p)
                    StatusCenter.post("Opened “\(item.name)”. Saved changes are uploaded back automatically.")
                }
            } catch {
                DispatchQueue.main.async { StatusCenter.error("Could not open “\(item.name)”: \(error.localizedDescription)") }
            }
        }
    }

    private static func watch(_ local: URL, remote: URL, provider: RemoteProvider) {
        watchers[local.path]?.cancel()
        let fd = Darwin.open(local.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global())
        var pending: DispatchWorkItem?
        src.setEventHandler {
            pending?.cancel()
            let replaced = src.data.contains(.rename) || src.data.contains(.delete)
            let work = DispatchWorkItem {
                guard FileManager.default.fileExists(atPath: local.path) else {
                    // Deleted for good: nothing left to upload (unless the file was opened again meanwhile).
                    DispatchQueue.main.async { if watchers[local.path] === src { unwatch(local) } }
                    return
                }
                // Editors often save by replacing the file: watch the new one before uploading, so a
                // save made while the upload runs is not missed.
                if replaced { DispatchQueue.main.async { watch(local, remote: remote, provider: provider) } }
                var failure: Error?
                do { try provider.upload(local, into: remote.deletingLastPathComponent()) } catch { failure = error }
                DispatchQueue.main.async {
                    if let e = failure {
                        StatusCenter.error("Could not upload “\(remote.lastPathComponent)”: \(e.localizedDescription)")
                    } else {
                        StatusCenter.post("Uploaded changes to “\(remote.lastPathComponent)”.")
                        FileOperationsController.notifyChanged([remote])
                    }
                }
            }
            pending = work
            uploadQueue.asyncAfter(deadline: .now() + uploadDelay, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers[local.path] = src
    }

    private static func unwatch(_ local: URL) {
        watchers.removeValue(forKey: local.path)?.cancel()
    }
}

/// Short app-wide messages shown in the active view's status bar.
enum StatusCenter {
    static let message = Notification.Name("PorpoiseStatusMessage")
    static func post(_ s: String) { NotificationCenter.default.post(name: message, object: s) }
    static func error(_ s: String) { NotificationCenter.default.post(name: message, object: s, userInfo: ["error": true]) }
}

// MARK: - Native mounts (SMB, AFP, NFS, WebDAV)

/// Mounts network shares with macOS itself (NetFS): native login dialog and Keychain, then browsed as folders.
enum NetworkMounts {
    static func needsMount(_ url: URL) -> Bool { RemoteFS.mountSchemes.contains(url.scheme?.lowercased() ?? "") }

    /// Returns the local mount point (asynchronously), or an error message.
    static func mount(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        var u = url
        // WebDAV variants → http(s) as NetFS expects.
        if let s = url.scheme?.lowercased(), ["webdav", "dav", "webdavs", "davs"].contains(s) {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.scheme = s.hasSuffix("s") ? "https" : "http"
            u = c?.url ?? url
        }
        if url.scheme?.lowercased() == "cifs" { u = URL(string: url.absoluteString.replacingOccurrences(of: "cifs://", with: "smb://")) ?? url }
        // Already mounted?
        if let existing = mountedVolume(for: u) { completion(.success(existing)); return }
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        let mountOptions = NSMutableDictionary()
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(u as CFURL, nil, nil, nil, openOptions, mountOptions, &request, DispatchQueue.main) { status, _, mountpoints in
            if status == 0, let mp = (mountpoints as? [String])?.first {
                // Keep the path inside the share (smb://host/share/sub/dir → /Volumes/share/sub/dir).
                let parts = u.pathComponents.filter { $0 != "/" }
                var dest = URL(fileURLWithPath: mp)
                for p in parts.dropFirst() { dest.appendPathComponent(p) }
                PlacesModel.shared.refreshDevices()
                completion(.success(dest))
            } else {
                let msg = status == ECANCELED || status == Int32(-128) ? "Connection cancelled." : "Could not connect to \(u.host ?? u.absoluteString) (error \(status))."
                completion(.failure(RemoteError.failed(msg)))
            }
        }
        if status != 0 && status != Int32(EINPROGRESS) && request == nil {
            completion(.failure(RemoteError.failed("Could not connect to \(u.host ?? "") (error \(status)).")))
        }
    }

    private static func mountedVolume(for url: URL) -> URL? {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        for v in vols {
            guard let remount = try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                  remount.host?.lowercased() == url.host?.lowercased(), remount.scheme?.lowercased() == url.scheme?.lowercased() else { continue }
            let share = url.pathComponents.dropFirst().first
            if share == nil || remount.pathComponents.dropFirst().first == share {
                var dest = v
                for p in url.pathComponents.filter({ $0 != "/" }).dropFirst() { dest.appendPathComponent(p) }
                return dest
            }
        }
        return nil
    }
}

// MARK: - Network browsing (Dolphin's remote:/ — "Network")

/// Discovers file servers on the local network with Bonjour (SMB, AFP, SFTP/SSH, FTP, WebDAV, NFS).
final class NetworkBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = NetworkBrowser()
    static let changed = Notification.Name("PorpoiseNetworkChanged")
    static let url = URL(string: "network:/")!
    private static let resolveTimeout: TimeInterval = 5

    struct Server: Hashable { let name: String; let url: URL; let kind: String }
    private(set) var servers: [Server] = []
    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []
    private let types: [(String, String, String)] = [
        ("_smb._tcp.", "smb", "Windows / SMB share"), ("_afpovertcp._tcp.", "afp", "Apple file server"),
        ("_sftp-ssh._tcp.", "sftp", "SFTP server"), ("_ssh._tcp.", "sftp", "SSH server"), ("_ftp._tcp.", "ftp", "FTP server"),
        ("_webdav._tcp.", "webdav", "WebDAV server"), ("_webdavs._tcp.", "webdavs", "WebDAV server (secure)"), ("_nfs._tcp.", "nfs", "NFS server"),
    ]

    func start() {
        guard browsers.isEmpty else { return }
        for (t, _, _) in types {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: t, inDomain: "local.")
            browsers.append(b)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: Self.resolveTimeout)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
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
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        // Only this service's entry: one machine often offers several (SMB and SFTP under one name).
        let kind = types.first { $0.0 == service.type }?.2
        servers.removeAll { $0.name == service.name && $0.kind == kind }
        resolving.removeAll { $0 === service }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Items for the network:/ view.
    var items: [FileItem] {
        servers.map { s in
            FileItem(url: s.url, name: "\(s.name) (\(s.url.scheme?.uppercased() ?? ""))", isDirectory: true, contentType: "public.folder")
        }
    }
}

// MARK: - Cloud storage (Google Drive, OneDrive, Dropbox, Box… via their Mac apps)

enum CloudStorage {
    /// Folders that File Provider apps create in ~/Library/CloudStorage (e.g. "GoogleDrive-me@gmail.com").
    static func locations() -> [(title: String, url: URL, icon: String)] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { n in
            guard !n.hasPrefix(".") else { return nil }
            let u = root.appendingPathComponent(n)
            let lower = n.lowercased()
            let (title, icon): (String, String) = {
                if lower.hasPrefix("googledrive") { return ("Google Drive", "folder-gdrive") }
                if lower.hasPrefix("onedrive") { return ("OneDrive", "folder-onedrive") }
                if lower.hasPrefix("dropbox") { return ("Dropbox", "folder-dropbox") }
                if lower.hasPrefix("box") { return ("Box", "folder-cloud") }
                if lower.hasPrefix("pcloud") { return ("pCloud", "folder-pcloud") }
                return (n.components(separatedBy: "-").first ?? n, "folder-cloud")
            }()
            let account = n.contains("-") ? " (" + n.components(separatedBy: "-").dropFirst().joined(separator: "-") + ")" : ""
            return (title + account, u, Icons.shared.has(icon) ? icon : "folder-cloud")
        }
    }
}

// MARK: - Archives as folders

/// "Browse compressed files as folders": archives open as a read-only extracted copy in the cache.
enum ArchiveBrowser {
    static let extensions: Set<String> = ["zip", "tar", "tgz", "gz", "bz2", "tbz", "xz", "txz", "7z", "rar", "iso", "jar", "cpio", "xar", "zst"]

    static func isArchive(_ item: FileItem) -> Bool {
        let n = item.name.lowercased()
        return !item.isBrowsableFolder && (extensions.contains(item.fileExtension.lowercased()) || n.hasSuffix(".tar.gz") || n.hasSuffix(".tar.xz"))
    }

    /// Extracts once per archive version into the cache. The folder name is a stable digest of the path
    /// (String.hashValue changes every launch, which defeated the cache and piled up copies), and
    /// extraction happens in a temporary folder that is renamed into place only when complete, so an
    /// interrupted extraction is never mistaken for a finished one.
    static func extractedFolder(for item: FileItem, completion: @escaping (Result<URL, Error>) -> Void) {
        let stamp = Int(item.modificationDate?.timeIntervalSince1970 ?? 0)
        let digest = SHA256.hash(data: Data(item.url.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let parent = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porpoise/archives/\(digest)-\(stamp)")
        let dir = parent.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: dir.path) { completion(.success(dir)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Copies extracted from earlier versions of this archive are stale now: free their space.
            let cache = parent.deletingLastPathComponent()
            for old in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
            where old.hasPrefix(digest + "-") && old != parent.lastPathComponent {
                try? FileManager.default.removeItem(at: cache.appendingPathComponent(old))
            }
            let partial = parent.appendingPathComponent(".partial-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
                // bsdtar (libarchive) reads zip, tar.*, 7z, rar, iso, xar, cpio… and by default refuses
                // absolute paths, ".." and extracting through symlinks.
                let r = try Shell.run("/usr/bin/tar", ["-xf", item.url.path, "-C", partial.path])
                if r.status != 0 { throw RemoteError.failed(r.err.isEmpty ? "Could not read the archive." : r.err) }
                do {
                    try FileManager.default.moveItem(at: partial, to: dir)
                } catch where FileManager.default.fileExists(atPath: dir.path) {
                    try? FileManager.default.removeItem(at: partial)   // extracted concurrently by another request
                }
                DispatchQueue.main.async { completion(.success(dir)) }
            } catch {
                try? FileManager.default.removeItem(at: partial)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
