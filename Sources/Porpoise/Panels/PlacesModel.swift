import AppKit
import PorpoiseCore
import PorpoiseServices

enum PlaceSection: String, Codable, CaseIterable {
    case places = "Places", remote = "Remote", recent = "Recent", tags = "Tags", devices = "Devices", removable = "Removable Devices"
}

struct PlaceEntry: Codable, Equatable {
    var title: String
    var url: URL
    var icon: String
    var section: PlaceSection
    var hidden = false
    var isVolume = false
    var isEjectable = false
}

/// Dolphin's KFilePlacesModel: default places, user bookmarks (persisted), mounted volumes,
/// detected cloud folders and Android phones, and Finder tags.
final class PlacesModel {
    static let shared = PlacesModel()
    static let changed = Notification.Name("PorpoisePlacesChanged")

    static let recentFilesURL = URL(string: "recent:/files")!
    static let recentLocationsURL = URL(string: "recent:/locations")!
    /// How often Android phones are polled while adb is installed.
    private static let adbPollInterval: TimeInterval = 4

    private(set) var userEntries: [PlaceEntry] = []
    private(set) var devices: [PlaceEntry] = []
    /// Cloud storage folders (Google Drive, OneDrive…); those also bookmarked are left out by `detected`.
    private var cloudEntries: [PlaceEntry] = []
    /// Android phones seen by `adb devices`.
    private var phoneEntries: [PlaceEntry] = []
    /// Finder's colored tags (Dolphin lists Baloo tags the same way).
    let tagEntries: [PlaceEntry] = FinderTags.standard.map {
        PlaceEntry(title: $0.name, url: FinderTags.url(for: $0.name), icon: "tag", section: .tags)
    }

    var hiddenSections: Set<PlaceSection> {
        get { storedHiddenSections }
        set { storedHiddenSections = newValue; save() }
    }
    private var storedHiddenSections: Set<PlaceSection> = []

    /// Folded sections show only their header.
    var collapsedSections: Set<PlaceSection> = [] { didSet { if ready, collapsedSections != oldValue { save() } } }
    /// Section order (the user can drag headers); always contains every section.
    private(set) var sectionOrder: [PlaceSection] = PlaceSection.allCases
    /// Locked: no dragging or reordering of places and sections (folding still works).
    var isLocked = false { didSet { if ready, isLocked != oldValue { save() } } }

    func toggleCollapsed(_ sec: PlaceSection) {
        if collapsedSections.contains(sec) { collapsedSections.remove(sec) } else { collapsedSections.insert(sec) }
    }

    /// Moves `sec` before `target` (nil = to the end).
    func moveSection(_ sec: PlaceSection, before target: PlaceSection?) {
        guard let order = sectionOrder(moving: sec, before: target) else { return }
        sectionOrder = order
        save()
    }

    /// Whether `moveSection(_:before:)` would change the order (a drop right before or after itself doesn't).
    func canMoveSection(_ sec: PlaceSection, before target: PlaceSection?) -> Bool {
        sectionOrder(moving: sec, before: target) != nil
    }

    private func sectionOrder(moving sec: PlaceSection, before target: PlaceSection?) -> [PlaceSection]? {
        guard sec != target else { return nil }
        var order = sectionOrder.filter { $0 != sec }
        order.insert(sec, at: target.flatMap { order.firstIndex(of: $0) } ?? order.count)
        return order != sectionOrder ? order : nil
    }

    private static func normalizedOrder(_ stored: [PlaceSection]?) -> [PlaceSection] {
        var order = (stored ?? []).reduce(into: [PlaceSection]()) { if !$0.contains($1) { $0.append($1) } }
        for s in PlaceSection.allCases where !order.contains(s) { order.append(s) }   // sections added in later versions
        return order
    }
    var showHidden = false { didSet { post() } }

    private var adbTimer: Timer?
    private var adbPollInFlight = false
    /// Notifications are held back until the initial load is done.
    private var ready = false

    private lazy var storeURL: URL = {
        let fm = FileManager.default
        let dir = Settings.isTesting ? fm.temporaryDirectory.appendingPathComponent("porpoise-test")
            : fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("places.json")
    }()

    private init() {
        load()
        refreshDevices()
        ready = true
        DispatchQueue.main.async { self.refreshDetected() }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshDevices() }
        }
    }

    // MARK: Entries

    /// Detected cloud folders that aren't bookmarked (adding or removing a bookmark takes effect at once), and phones.
    var detected: [PlaceEntry] {
        let bookmarked = Set(userEntries.map(\.url.standardizedFileURL))
        return cloudEntries.filter { !bookmarked.contains($0.url.standardizedFileURL) } + phoneEntries
    }
    var allEntries: [PlaceEntry] { userEntries + detected + tagEntries + devices }

    /// Entries grouped by section, honoring hidden flags.
    func sections() -> [(PlaceSection, [PlaceEntry])] {
        let all = allEntries
        return sectionOrder.compactMap { sec in
            guard showHidden || !hiddenSections.contains(sec) else { return nil }
            let list = all.filter { $0.section == sec && (showHidden || !$0.hidden) }
            return list.isEmpty ? nil : (sec, list)
        }
    }

    func isUserEntry(_ entry: PlaceEntry) -> Bool { userIndex(of: entry) != nil }

    func contains(_ url: URL) -> Bool {
        let u = url.standardizedFileURL
        return allEntries.contains { $0.url.standardizedFileURL == u }
    }

    /// Title for a URL if it is a place (window/tab titles use it, e.g. "Home").
    func title(for url: URL) -> String? {
        if url.scheme == "smart" { return url.deletingPathExtension().lastPathComponent }
        let u = url.standardizedFileURL
        return allEntries.first { $0.url.standardizedFileURL == u }?.title
    }

    static func defaultEntries() -> [PlaceEntry] {
        let h = FileManager.default.homeDirectoryForCurrentUser
        var e: [PlaceEntry] = [
            PlaceEntry(title: "Home", url: h, icon: "user-home", section: .places),
            PlaceEntry(title: "Desktop", url: h.appendingPathComponent("Desktop"), icon: "user-desktop", section: .places),
            PlaceEntry(title: "Documents", url: h.appendingPathComponent("Documents"), icon: "folder-documents", section: .places),
            PlaceEntry(title: "Downloads", url: h.appendingPathComponent("Downloads"), icon: "folder-download", section: .places),
            PlaceEntry(title: "Music", url: h.appendingPathComponent("Music"), icon: "folder-music", section: .places),
            PlaceEntry(title: "Pictures", url: h.appendingPathComponent("Pictures"), icon: "folder-pictures", section: .places),
            PlaceEntry(title: "Videos", url: h.appendingPathComponent("Movies"), icon: "folder-videos", section: .places),
            PlaceEntry(title: "Applications", url: URL(fileURLWithPath: "/Applications"), icon: "view-list-icons", section: .places),
            PlaceEntry(title: "Trash", url: h.appendingPathComponent(".Trash"), icon: "user-trash", section: .places),
            networkEntry,
        ]
        let icloud = h.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloud.path) {
            e.append(PlaceEntry(title: "iCloud Drive", url: icloud, icon: "folder-cloud", section: .remote))
        }
        e.append(PlaceEntry(title: "Recent Files", url: recentFilesURL, icon: "document-open-recent", section: .recent))
        e.append(PlaceEntry(title: "Recent Locations", url: recentLocationsURL, icon: "folder-open-recent", section: .recent))
        return e
    }

    private static var networkEntry: PlaceEntry {
        PlaceEntry(title: "Network", url: NetworkBrowser.url, icon: "network-workgroup", section: .remote)
    }

    // MARK: Persistence

    /// places.json. Fields added later are optional so older files still load.
    private struct Stored: Codable {
        var entries: [PlaceEntry]
        var hiddenSections: [PlaceSection]
        var collapsedSections: [PlaceSection]?
        var sectionOrder: [PlaceSection]?
        var locked: Bool?
        /// Format version: nil for files written before it existed (they get the places added since).
        var version: Int?
    }
    private static let storeVersion = 1

    private func load() {
        guard !Settings.isTesting, let data = try? Data(contentsOf: storeURL) else {
            userEntries = Self.defaultEntries()
            return
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            // Unreadable (damaged, or written by a newer version): keep a copy instead of silently overwriting it.
            let backup = storeURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: storeURL, to: backup)
            NSLog("Porpoise: places.json could not be read; a copy was kept as \(backup.lastPathComponent)")
            userEntries = Self.defaultEntries()
            return
        }
        userEntries = stored.entries.map(Self.migrated)
        // Places added in later versions, offered once (a place the user removed afterwards stays removed).
        if stored.version == nil, !userEntries.contains(where: { $0.url == NetworkBrowser.url }) {
            let at = userEntries.firstIndex { $0.section == .remote } ?? userEntries.count
            userEntries.insert(Self.networkEntry, at: at)
        }
        storedHiddenSections = Set(stored.hiddenSections)
        collapsedSections = Set(stored.collapsedSections ?? [])
        sectionOrder = Self.normalizedOrder(stored.sectionOrder)
        isLocked = stored.locked ?? false
        // Record the migration, so places added for older files aren't added again on every launch.
        if stored.version != Self.storeVersion { save() }
    }

    /// Icons that the theme doesn't have (older versions stored some) fall back to sensible ones.
    private static func migrated(_ entry: PlaceEntry) -> PlaceEntry {
        var e = entry
        if e.url.path == "/Applications" && ["folder-appimage", "applications-other"].contains(e.icon) { e.icon = "view-list-icons" }
        if !Icons.shared.has(e.icon) { e.icon = e.url.isFileURL ? Icons.folderIconName(e.url) : "folder-remote" }
        return e
    }

    private func save() {
        let s = Stored(entries: userEntries, hiddenSections: Array(storedHiddenSections), collapsedSections: Array(collapsedSections),
                       sectionOrder: sectionOrder, locked: isLocked, version: Self.storeVersion)
        if !Settings.isTesting { try? JSONEncoder().encode(s).write(to: storeURL) }
        post()
    }

    private func post() { if ready { NotificationCenter.default.post(name: Self.changed, object: nil) } }

    // MARK: Devices and detected places

    func refreshDevices() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
                                      .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        devices = vols.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
            // Mounted network shares (SMB, AFP, NFS, WebDAV): listed with the devices and unmountable, as in Finder.
            if v.volumeIsLocal == false {
                return PlaceEntry(title: v.volumeLocalizedName ?? u.lastPathComponent, url: u, icon: "folder-network",
                                  section: .devices, isVolume: true, isEjectable: true)
            }
            let removable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false) || !(v.volumeIsInternal ?? true)
            let icon = removable && v.volumeIsRootFileSystem != true ? "drive-removable-media-usb" : "drive-harddisk"
            return PlaceEntry(title: v.volumeLocalizedName ?? u.lastPathComponent, url: u, icon: icon,
                              section: removable ? .removable : .devices, isVolume: true, isEjectable: v.volumeIsEjectable ?? removable)
        }
        post()
    }

    /// Cloud storage folders, and Android phones (polled while adb is installed; adb runs off the main thread).
    func refreshDetected() {
        let cloud = CloudStorage.locations().map { PlaceEntry(title: $0.title, url: $0.url, icon: $0.icon, section: .remote) }
        if cloud != cloudEntries { cloudEntries = cloud; post() }
        guard ADBProvider.adbPath != nil else { return }
        pollPhones()
        if adbTimer == nil {
            adbTimer = Timer.scheduledTimer(withTimeInterval: Self.adbPollInterval, repeats: true) { [weak self] _ in self?.pollPhones() }
        }
    }

    private func pollPhones() {
        guard !adbPollInFlight else { return }
        adbPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let phones = ADBProvider.devices()
            DispatchQueue.main.async {
                guard let self else { return }
                self.adbPollInFlight = false
                let entries = phones.compactMap { p in
                    URL(string: "adb://\(p.serial)/sdcard/").map { PlaceEntry(title: p.model, url: $0, icon: "smartphone", section: .removable) }
                }
                if entries != self.phoneEntries { self.phoneEntries = entries; self.post() }
            }
        }
    }

    // MARK: Editing

    func add(_ url: URL, title: String? = nil) {
        guard !userEntries.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        if !url.isFileURL {
            // Network folders go to the end of the Remote section.
            let entry = PlaceEntry(title: title ?? (url.host ?? url.absoluteString), url: url, icon: "folder-remote", section: .remote)
            let at = userEntries.lastIndex { $0.section == .remote }.map { $0 + 1 } ?? userEntries.count
            userEntries.insert(entry, at: at)
        } else {
            // Folders go after the last "Places" entry, before Trash if present.
            let entry = PlaceEntry(title: title ?? url.lastPathComponent, url: url, icon: Icons.folderIconName(url), section: .places)
            let afterLast = (userEntries.lastIndex { $0.section == .places } ?? (userEntries.count - 1)) + 1
            let at = userEntries.firstIndex { $0.icon == "user-trash" } ?? afterLast
            userEntries.insert(entry, at: max(0, at))
        }
        save()
    }

    func remove(_ entry: PlaceEntry) {
        guard let i = userIndex(of: entry) else { return }
        userEntries.remove(at: i)
        save()
    }

    func update(_ entry: PlaceEntry, title: String, url: URL) {
        guard let i = userIndex(of: entry) else { return }
        userEntries[i].title = title
        userEntries[i].url = url
        save()
    }

    func setHidden(_ entry: PlaceEntry, _ hidden: Bool) {
        guard let i = userIndex(of: entry) else { return }
        userEntries[i].hidden = hidden
        save()
    }

    /// Whether `move(_:before:endOf:)` would accept this drop.
    func canMove(_ entry: PlaceEntry, before target: PlaceEntry?, endOf section: PlaceSection) -> Bool {
        reordered(entry, before: target, endOf: section) != nil
    }

    /// Reorders within the entry's own section: before `target`, or at the end of `section` when target is nil.
    func move(_ entry: PlaceEntry, before target: PlaceEntry?, endOf section: PlaceSection) {
        guard let list = reordered(entry, before: target, endOf: section), list != userEntries else { return }
        userEntries = list
        save()
    }

    private func reordered(_ entry: PlaceEntry, before target: PlaceEntry?, endOf section: PlaceSection) -> [PlaceEntry]? {
        guard let from = userEntries.firstIndex(of: entry), target != entry else { return nil }
        if let target {
            guard target.section == entry.section, userEntries.contains(target) else { return nil }
        } else {
            guard section == entry.section else { return nil }
        }
        var list = userEntries
        list.remove(at: from)
        let at = target.map { t in list.firstIndex(of: t) ?? list.count }
            ?? list.lastIndex { $0.section == section }.map { $0 + 1 } ?? list.count
        list.insert(entry, at: at)
        return list
    }

    func resetDefaults() {
        userEntries = Self.defaultEntries()
        storedHiddenSections = []
        sectionOrder = PlaceSection.allCases
        collapsedSections = []
        save()
    }

    /// User entries are identified by location and label (the same folder may be bookmarked twice under different names).
    private func userIndex(of entry: PlaceEntry) -> Int? {
        userEntries.firstIndex { $0.url == entry.url && $0.title == entry.title }
    }
}
