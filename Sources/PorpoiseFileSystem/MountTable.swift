import Darwin
import Foundation

/// The mounted file systems as the kernel last listed them: asked without waiting on any of them (`MNT_NOWAIT`), so a
/// share whose server is gone answers at once, where a stat of a path on it would hang.
public enum MountTable {
    /// Whether `path` is on a file system that isn't local (a network share: SMB, AFP, NFS, WebDAV…). A path no mount
    /// covers counts as local.
    public static func isNetwork(_ path: String) -> Bool { !(mount(of: path)?.local ?? true) }

    /// Where the file system holding `path` is mounted ("/", "/Volumes/Disk"…), by the path alone: nothing on it is
    /// asked. Two paths with the same mount point are on the same volume (the data volume's firmlinked folders all
    /// answer "/").
    public static func mountPoint(of path: String) -> String? { mount(of: path)?.on }

    private static func mount(of path: String) -> (on: String, local: Bool)? {
        var mounts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&mounts, MNT_NOWAIT)
        guard n > 0, let mounts else { return nil }
        var best: (on: String, local: Bool)?
        for i in 0..<Int(n) {
            var m = mounts[i]
            let on = withUnsafeBytes(of: &m.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let prefix = on == "/" ? "/" : on + "/"
            guard path == on || path.hasPrefix(prefix), on.count > (best?.on.count ?? -1) else { continue }
            best = (on, m.f_flags & UInt32(MNT_LOCAL) != 0)
        }
        return best
    }
}
