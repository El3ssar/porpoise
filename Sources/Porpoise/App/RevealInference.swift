import AppKit
import UniformTypeIdentifiers

/// Reveal requests that arrive without the item. A sandboxed app calling activateFileViewerSelectingURLs: may not send
/// the NSFileViewer app an Apple Event, so macOS only launches it ('oapp', sent by LaunchServices) or reopens it ('rapp',
/// carrying the sender's quarantine info). That is how Archive Utility reveals what it unpacked (a zip clicked in the
/// Dock's Downloads stack). The item is then found on disk: Archive Utility unpacks next to the archive, which
/// LaunchServices marks as just used when it opens it, and the unpacked item is added to that folder right before the
/// request. (Unsandboxed apps' reveals arrive as 'odoc' with the items, handled by application(_:open:).)
enum RevealInference {
    static let archiveUtility = "com.apple.archiveutility"
    /// How long before the request the item may have been added: the request follows right after.
    static let window: TimeInterval = 30

    /// The app that sent `event`: the running app with the sender's pid, else the one named in the quarantine info
    /// LaunchServices attaches for a sandboxed sender (which may have quit already).
    static func sender(of event: NSAppleEventDescriptor) -> String? {
        let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        if pid > 0, pid != getpid(), let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { return id }
        guard let data = event.paramDescriptor(forKeyword: SystemIntegration.fourCC("qtnp"))?.data,
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["LSQuarantineAgentBundleIdentifier"] as? String
    }

    /// What a reopen asks to reveal: what Archive Utility just unpacked, when it sent the reopen.
    static func reopenItem(_ event: NSAppleEventDescriptor, folders: [URL], now: Date = Date()) -> URL? {
        guard event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEReopenApplication),
            sender(of: event) == archiveUtility
        else { return nil }
        return recentItem(in: folders, now: now, besideArchive: true) ?? recentItem(in: folders, now: now, besideArchive: false)
    }

    /// What a launch without documents asks to reveal. LaunchServices sends the launch, so who asked is unknown: an item
    /// just added beside an archive just opened, or Archive Utility still running, tells it was Archive Utility.
    static func launchItem(
        folders: [URL], archiveUtilityRunning: Bool = !NSRunningApplication.runningApplications(withBundleIdentifier: archiveUtility).isEmpty,
        now: Date = Date()
    ) -> URL? {
        recentItem(in: folders, now: now, besideArchive: true)
            ?? (archiveUtilityRunning ? recentItem(in: folders, now: now, besideArchive: false) : nil)
    }

    /// Where unpacked items are looked for: Archive Utility's usual places, then the folders Porpoise shows (or showed).
    static func folders(shown: [URL]) -> [URL] {
        let fm = FileManager.default
        let usual =
            [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first } + [fm.homeDirectoryForCurrentUser]
        var seen = Set<String>()
        return (usual + shown.filter(\.isFileURL)).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The item added last to one of `folders`, at most `window` seconds before `now`; with `besideArchive`, only one
    /// added after an archive in its folder was opened.
    static func recentItem(in folders: [URL], now: Date = Date(), besideArchive: Bool) -> URL? {
        let since = now.addingTimeInterval(-window)
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .attributeModificationDateKey, .contentTypeKey]
        // Date added; where the volume keeps none, the last metadata change (moving the item in counts).
        func added(_ u: URL) -> Date? {
            let v = try? u.resourceValues(forKeys: keys)
            return v?.addedToDirectoryDate ?? v?.attributeModificationDate
        }
        var best: (url: URL, added: Date)?
        for folder in folders {
            // Adding an item changes its folder: folders unchanged since are skipped without being listed.
            guard let changed = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                changed >= since,
                let items = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            else { continue }
            let fresh = items.compactMap { u in added(u).map { (url: u, added: $0) } }
                .filter { $0.added >= since && $0.added <= now.addingTimeInterval(5) }
            guard let newest = fresh.max(by: { $0.added < $1.added }) else { continue }
            if besideArchive {
                // Opened before the item came (up to an hour of unpacking), not after.
                let opened = items.filter { $0 != newest.url && isArchive($0) }.compactMap(lastUsed)
                guard opened.contains(where: { $0 <= newest.added.addingTimeInterval(2) && $0 >= newest.added.addingTimeInterval(-3600) })
                else { continue }
            }
            if best.map({ newest.added > $0.added }) ?? true { best = newest }
        }
        return best?.url
    }

    static func isArchive(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .archive) ?? false
    }

    /// When LaunchServices last opened `url`: its com.apple.lastuseddate#PS attribute, a timespec.
    static func lastUsed(_ url: URL) -> Date? {
        var ts = timespec()
        let n = url.withUnsafeFileSystemRepresentation { p in
            p.map { getxattr($0, "com.apple.lastuseddate#PS", &ts, MemoryLayout<timespec>.size, 0, 0) } ?? -1
        }
        guard n == MemoryLayout<timespec>.size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }
}
