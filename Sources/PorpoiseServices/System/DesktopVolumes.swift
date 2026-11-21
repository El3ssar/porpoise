import Foundation
import PorpoiseCore

/// The disks on Porpoise's desktop: those Finder would show there, under Finder's own "Show these items on the
/// desktop" choices (Finder › Settings › General).
public enum DesktopVolumes {
    public enum Kind: Equatable, Sendable { case hardDisk, externalDisk, removableMedia, server }

    public struct Shown: Equatable, Sendable {
        public var hardDisks = false, externalDisks = true, removableMedia = true, servers = false
        public init(hardDisks: Bool = false, externalDisks: Bool = true, removableMedia: Bool = true, servers: Bool = false) {
            self.hardDisks = hardDisks
            self.externalDisks = externalDisks
            self.removableMedia = removableMedia
            self.servers = servers
        }

        /// Finder's defaults where a choice isn't set (or can't be read).
        public static func finder(_ preferences: DesktopPreferences?) -> Self {
            var shown = Self()
            guard let preferences else { return shown }
            func read(_ key: String, _ fallback: Bool) -> Bool { preferences.flag(DesktopPreferences.finder, key, default: fallback) ?? fallback }
            shown.hardDisks = read("ShowHardDrivesOnDesktop", false)
            shown.externalDisks = read("ShowExternalHardDrivesOnDesktop", true)
            shown.removableMedia = read("ShowRemovableMediaOnDesktop", true)
            shown.servers = read("ShowMountedServersOnDesktop", false)
            return shown
        }

        public func includes(_ kind: Kind) -> Bool {
            switch kind {
            case .hardDisk: hardDisks
            case .externalDisk: externalDisks
            case .removableMedia: removableMedia
            case .server: servers
            }
        }
    }

    static let keys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey, .volumeTypeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
    ]

    /// Optical discs' file systems: Finder's "CDs, DVDs and iPods".
    static let discFileSystems: Set<String> = ["cd9660", "udf", "cddafs"]

    /// Mounted servers, then discs, then internal disks; the rest (USB drives and cards, disk images) are external disks,
    /// as Finder groups them. macOS calls USB drives and disk images removable too, so that flag doesn't decide.
    public static func kind(isLocal: Bool?, fileSystem: String?, isInternal: Bool?) -> Kind {
        if isLocal == false { return .server }
        if let fileSystem, discFileSystems.contains(fileSystem.lowercased()) { return .removableMedia }
        if isInternal == true { return .hardDisk }
        return .externalDisk
    }

    /// The shown disks in macOS's mount order (the startup disk first), as folder items named as Finder names them.
    public static func items(shown: Shown, volumes: [URL]) -> [FileItem] {
        volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsBrowsable != false,
                shown.includes(kind(isLocal: values.volumeIsLocal, fileSystem: values.volumeTypeName, isInternal: values.volumeIsInternal))
            else { return nil }
            return FileItem(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent, isDirectory: true)
        }
    }

    public static func current(_ preferences: DesktopPreferences? = DesktopPreferences.current()) -> [FileItem] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return items(shown: .finder(preferences), volumes: volumes)
    }

    /// Where every disk is mounted (the startup disk, /Volumes, and anywhere else, such as a FUSE mount in the home
    /// folder), from the kernel's mount table in one call. Ask once for a batch of items.
    public static func mountPoints() -> Set<String> {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return ["/"] }
        let table = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { table.deallocate() }
        let filled = getfsstat(table, Int32(MemoryLayout<statfs>.stride * Int(count)), MNT_NOWAIT)
        guard filled > 0 else { return ["/"] }
        return Set(
            (0..<Int(filled)).map { index in
                withUnsafeBytes(of: table[index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            })
    }

    /// Whether `url` is a disk's top level: where it is mounted. A disk can be ejected but never moved, trashed or
    /// deleted.
    public static func isVolume(_ url: URL, mounts: Set<String>? = nil) -> Bool {
        guard url.isFileURL else { return false }
        let mounts = mounts ?? mountPoints()
        if mounts.contains(url.standardizedFileURL.path) { return true }
        // Another spelling of a mount point (other letter case, a symbolic link on the way, as /tmp for /private/tmp):
        // a name that a mount point ends with is asked of the disk itself.
        let name = url.lastPathComponent.lowercased()
        guard mounts.contains(where: { ($0 as NSString).lastPathComponent.lowercased() == name }) else { return false }
        return (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    /// Whether a disk can be ejected: any but the startup disk, as in Finder.
    public static func isEjectable(_ url: URL, mounts: Set<String>? = nil) -> Bool {
        isVolume(url, mounts: mounts) && url.standardizedFileURL.path != "/"
            && (try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey]).volumeIsRootFileSystem) != true
    }
}
