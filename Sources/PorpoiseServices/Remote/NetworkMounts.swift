import Foundation
import NetFS

/// Mounts network shares with macOS itself (NetFS): native login dialog and Keychain, then browsed as folders.
public enum NetworkMounts {
    public static func needsMount(_ url: URL) -> Bool { RemoteFS.mountSchemes.contains(url.scheme?.lowercased() ?? "") }

    /// Returns the local mount point (asynchronously), or an error message.
    public static func mount(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let profile = ConnectionProfiles.shared.profile(for: url)
        var components = URLComponents(url: mountURL(url), resolvingAgainstBaseURL: false)
        if profile?.kind == .smb, let user = profile?.user?.trimmingCharacters(in: .whitespaces), !user.isEmpty {
            components?.user = user
        }
        let u = components?.url ?? mountURL(url)
        // Already mounted?
        if let existing = mountedVolume(for: u) { completion(.success(existing)); return }
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        let mountOptions = NSMutableDictionary()
        var request: AsyncRequestID?
        // A saved connection's login, from the Keychain; without one, macOS asks (and finds what Finder saved).
        let saved = login(for: url)
        let status = NetFSMountURLAsync(
            u as CFURL, nil, saved?.user as CFString?, saved?.password as CFString?, openOptions, mountOptions, &request, DispatchQueue.main
        ) {
            status, _, mountpoints in
            if status == 0, let mp = (mountpoints as? [String])?.first {
                // Keep the path inside the share (smb://host/share/sub/dir → /Volumes/share/sub/dir).
                let parts = u.pathComponents.filter { $0 != "/" }
                var dest = URL(fileURLWithPath: mp)
                for p in parts.dropFirst() { dest.appendPathComponent(p) }
                PlacesModel.shared.refreshDevices()
                completion(.success(dest))
            } else {
                let msg: String
                if status == EEXIST {
                    msg = "macOS reports this share is already connected. Disconnect the existing share before trying this connection."
                } else {
                    msg =
                        status == ECANCELED || status == Int32(-128)
                        ? "Connection cancelled." : "Could not connect to \(u.host ?? u.absoluteString) (error \(status))."
                }
                completion(.failure(RemoteError.failed(msg)))
            }
        }
        if status != 0 && status != Int32(EINPROGRESS) && request == nil {
            completion(.failure(RemoteError.failed("Could not connect to \(u.host ?? "") (error \(status)).")))
        }
    }

    /// The user and password of the saved connection `url` is in, when its password is in the Keychain.
    static func login(
        for url: URL, profiles: ConnectionProfiles = .shared, credentials: ConnectionCredentials = .shared
    ) -> (user: String, password: String)? {
        guard let p = profiles.profile(for: url), p.kind == .smb, let user = p.user, let password = credentials.password(for: p) else { return nil }
        return (user, password)
    }

    /// The URL NetFS is given: WebDAV variants become http(s), as NetFS expects, and cifs becomes smb.
    static func mountURL(_ url: URL) -> URL {
        var u = url
        if let s = url.scheme?.lowercased(), ["webdav", "dav", "webdavs", "davs"].contains(s) {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.scheme = s.hasSuffix("s") ? "https" : "http"
            u = c?.url ?? url
        }
        if url.scheme?.lowercased() == "cifs" { u = URL(string: url.absoluteString.replacingOccurrences(of: "cifs://", with: "smb://")) ?? url }
        return u
    }

    static func mountedVolume(for url: URL) -> URL? {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        for v in vols {
            guard let remount = try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                let dest = path(of: url, onVolume: v, mountedFrom: remount)
            else { continue }
            return dest
        }
        return nil
    }

    /// Where `url` is on volume `v`, mounted from `remount`: same scheme, host, effective port, requested user and share (or no share asked for).
    static func path(of url: URL, onVolume v: URL, mountedFrom remount: URL) -> URL? {
        guard remount.host?.lowercased() == url.host?.lowercased(), remount.scheme?.lowercased() == url.scheme?.lowercased() else { return nil }
        if let user = url.user(percentEncoded: false), !user.isEmpty, user != remount.user(percentEncoded: false) { return nil }
        let defaults = ["smb": 445, "afp": 548, "nfs": 2049, "http": 80, "https": 443, "vnc": 5900]
        let defaultPort = defaults[url.scheme?.lowercased() ?? ""]
        guard (url.port ?? defaultPort) == (remount.port ?? defaultPort) else { return nil }
        let share = url.pathComponents.dropFirst().first
        guard share == nil || remount.pathComponents.dropFirst().first == share else { return nil }
        var dest = v
        for p in url.pathComponents.filter({ $0 != "/" }).dropFirst() { dest.appendPathComponent(p) }
        return dest
    }
}
