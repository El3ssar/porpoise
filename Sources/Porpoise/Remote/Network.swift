import AppKit
import CryptoKit
import NetFS
import PorpoiseCore
import PorpoiseServices

// MARK: - Opening remote files

/// Opens a remote file: downloads it to a cache, opens it, and uploads it again when the app saves changes
/// (KIO does the same for remote files opened in local applications).
enum RemoteOpener {
    private static var watchers: [String: DispatchSourceFileSystemObject] = [:]
    /// Local copies with saved changes not yet uploaded (the upload failed or hasn't run): only on the main queue.
    private static var unsynced: Set<String> = []

    /// Upload is delayed this long after the last change, so a burst of writes from one save uploads once.
    private static let uploadDelay: TimeInterval = 0.6
    /// Uploads run one at a time, so an older save can never land on the server after a newer one.
    private static let uploadQueue = DispatchQueue(label: "porpoise.remote-upload")

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
        let cached = folder.appendingPathComponent(item.url.lastPathComponent)
        // Opened again before its edits reached the server: open those edits, never replace them with a download.
        if unsynced.contains(cached.path), FileManager.default.fileExists(atPath: cached.path) {
            NSWorkspace.shared.open(cached)
            StatusCenter.post("Opened your copy of “\(item.name)”: its latest changes haven't been uploaded yet.")
            return
        }
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
            DispatchQueue.main.async { unsynced.insert(local.path) }
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
                        unsynced.remove(local.path)
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
