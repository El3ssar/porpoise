import Foundation
import NetFS

/// Mounts network shares with macOS itself (NetFS): native login dialog and Keychain, then browsed as folders.
public enum NetworkMounts {
    public static func needsMount(_ url: URL) -> Bool { RemoteFS.mountSchemes.contains(url.scheme?.lowercased() ?? "") }

    /// Returns the local mount point (asynchronously), or an error message.
    public static func mount(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
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
