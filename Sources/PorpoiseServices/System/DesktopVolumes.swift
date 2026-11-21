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

    /// Whether `url` is a disk's top level (the startup disk, or one mounted in /Volumes), which can be ejected but
    /// never moved or trashed. Other paths are ruled out without touching the disk.
    public static func isVolume(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        guard path == "/" || (path as NSString).deletingLastPathComponent == "/Volumes" else { return false }
        return (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }
}
