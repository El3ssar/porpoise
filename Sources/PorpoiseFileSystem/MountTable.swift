import Darwin
import Foundation

/// The mounted file systems as the kernel last listed them: asked without waiting on any of them (`MNT_NOWAIT`), so a
/// share whose server is gone answers at once, where a stat of a path on it would hang.
public enum MountTable {
    /// Whether `path` is on a file system that isn't local (a network share: SMB, AFP, NFS, WebDAV…). A path no mount
    /// covers counts as local.
    public static func isNetwork(_ path: String) -> Bool {
        var mounts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&mounts, MNT_NOWAIT)
        guard n > 0, let mounts else { return false }
        var best = (length: -1, local: true)
        for i in 0..<Int(n) {
            var m = mounts[i]
            let on = withUnsafeBytes(of: &m.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let prefix = on == "/" ? "/" : on + "/"
            guard path == on || path.hasPrefix(prefix), on.count > best.length else { continue }
            best = (on.count, m.f_flags & UInt32(MNT_LOCAL) != 0)
        }
        return !best.local
    }
}
