import AppKit
import PorpoiseCore

enum StatusBarMode: String, CaseIterable { case small, fullWidth, disabled }
enum TabStyle: String, CaseIterable { case autoSize, fixedSize, fullWidth }
enum CloseSplitChoice: String, CaseIterable { case active, inactive, right }
enum FolderSizeMode: String, CaseIterable { case itemCount, contentSize, none }
enum DateStyle: String, CaseIterable { case relative, absolute }
enum PermissionStyle: String, CaseIterable { case symbolic, numeric, combined }
enum StartupLocation: String, CaseIterable { case lastSession, home }
enum ExecutableAction: String, CaseIterable { case ask, open, run }
enum BackgroundDoubleClick: String, CaseIterable {
    case nothing, selectAll, goUp, newFolder, toggleHidden, openTerminal
    var title: String {
        switch self {
        case .nothing: return "Nothing"
        case .selectAll: return "Select All"
        case .goUp: return "Go Up"
        case .newFolder: return "Create New Folder"
        case .toggleHidden: return "Show/Hide Hidden Files"
        case .openTerminal: return "Open Terminal Here"
        }
    }
}

/// Context menu entries that can be switched on/off (Dolphin's Context Menu settings page).
enum ContextMenuEntry: String, CaseIterable {
    case addToPlaces, copyLocation, duplicate, openInNewTab, openInNewWindow, openInSplit, openTerminal, otherView,
         sortBy, viewMode, deleteAlongsideTrash, copyMoveTo, compress, tags, share, quickLook, revealInFinder
    var title: String {
        switch self {
        case .addToPlaces: return "Add to Places"
        case .copyLocation: return "Copy Location"
        case .duplicate: return "Duplicate Here"
        case .openInNewTab: return "Open in New Tab"
        case .openInNewWindow: return "Open in New Window"
        case .openInSplit: return "Open in Split View"
        case .openTerminal: return "Open Terminal Here"
        case .otherView: return "Copy/Move to Other View"
        case .sortBy: return "Sort By"
        case .viewMode: return "View Mode"
        case .deleteAlongsideTrash: return "Delete (next to Move to Trash)"
        case .copyMoveTo: return "“Copy To” and “Move To” commands"
        case .compress: return "Compress / Extract"
        case .tags: return "Tags"
        case .share: return "Share…"
        case .quickLook: return "Quick Look"
        case .revealInFinder: return "Reveal in Finder"
        }
    }
    /// Dolphin defaults: everything on except Delete-alongside and Copy To/Move To.
    var defaultOn: Bool { self != .deleteAlongsideTrash && self != .copyMoveTo }
}

/// One setting in `Settings.store`: `@Pref("key") var name: Type = default`. Enums are stored by raw value.
/// Writes post `Settings.changed` with the key, so open windows apply the change at once.
@propertyWrapper
struct Pref<Value> {
    let key: String
    let defaultValue: Value
    private let decode: (Any) -> Value?
    private let encode: (Value) -> Any

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
        decode = { $0 as? Value }
        encode = { $0 }
    }

    init(wrappedValue: Value, _ key: String) where Value: RawRepresentable, Value.RawValue == String {
        self.key = key
        defaultValue = wrappedValue
        decode = { ($0 as? String).flatMap(Value.init(rawValue:)) }
        encode = { $0.rawValue }
    }

    var wrappedValue: Value {
        get { Settings.store.object(forKey: key).flatMap(decode) ?? defaultValue }
        nonmutating set {
            Settings.store.set(encode(newValue), forKey: key)
            NotificationCenter.default.post(name: Settings.changed, object: key)
        }
    }
}

/// Global settings, stored in UserDefaults (Dolphin's dolphinrc equivalent).
/// Keys and defaults are part of the users' saved settings: never change them.
final class Settings {
    static let shared = Settings()
    static let changed = Notification.Name("PorpoiseSettingsChanged")
    /// Tests set PORPOISE_DEFAULTS_SUITE to use a throwaway defaults domain.
    private static let testSuite = ProcessInfo.processInfo.environment["PORPOISE_DEFAULTS_SUITE"]
    /// UserDefaults for everything the app stores.
    static let store: UserDefaults = testSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    static var isTesting: Bool { testSuite != nil }
    private let d = Settings.store

    private func get<T>(_ key: String, _ def: T) -> T { (d.object(forKey: key) as? T) ?? def }
    private func set(_ key: String, _ v: Any?) {
        d.set(v, forKey: key)
        NotificationCenter.default.post(name: Settings.changed, object: key)
    }

    // Interface › Folders & Tabs
    @Pref("startup") var startup: StartupLocation = .lastSession
    /// Stored as a path.
    @Pref("homeURL") private var homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    var homeURL: URL {
        get { URL(fileURLWithPath: homePath) }
        set { homePath = newValue.path }
    }
    @Pref("fullPathTitle") var showFullPathInTitle: Bool = false
    /// Applications as an app library (big icons, search) instead of a regular folder view.
    @Pref("appLibraryView") var appLibraryView: Bool = true
    @Pref("filterBar") var showFilterBarOnStartup: Bool = false
    @Pref("alwaysTabBar") var alwaysShowTabBar: Bool = false
    @Pref("tabClose") var closeButtonsOnTabs: Bool = true
    @Pref("tabStyle") var tabStyle: TabStyle = .autoSize
    @Pref("tabsAtEnd") var openNewTabsAtEnd: Bool = false
    @Pref("closeSplit") var closeSplitChoice: CloseSplitChoice = .active
    @Pref("splitStartup") var splitViewOnStartup: Bool = false

    @Pref("singleWindow") var singleWindow: Bool = false

    // Interface › Previews
    @Pref("pvImages") var previewImages: Bool = true
    @Pref("pvVideos") var previewVideos: Bool = true
    @Pref("pvDocs") var previewDocuments: Bool = true
    @Pref("pvText") var previewText: Bool = false
    @Pref("pvFonts") var previewFonts: Bool = true
    @Pref("pvFolders") var previewFolders: Bool = false
    /// Local files larger than this (MiB) get no preview; 0 = no limit.
    @Pref("pvMax") var previewMaxSizeMiB: Int = 100
    @Pref("pvRemote") var previewRemote: Bool = false

    // Interface › Status & Location bars
    @Pref("statusBar2") var statusBarMode: StatusBarMode = .fullWidth
    @Pref("zoomSlider2") var showZoomSlider: Bool = true
    @Pref("editableUrl") var editableLocation: Bool = false
    @Pref("fullPathUrl") var showFullPathInLocation: Bool = false

    // Interface › Confirmations
    @Pref("confirmTrash") var confirmTrash: Bool = false
    @Pref("confirmDelete") var confirmDelete: Bool = true
    @Pref("confirmEmptyTrash") var confirmEmptyTrash: Bool = true
    @Pref("confirmCloseTabs") var confirmCloseTabs: Bool = true
    @Pref("confirmTerminal") var confirmCloseTerminal: Bool = true
    @Pref("confirmOpenMany") var confirmOpenMany: Bool = true
    @Pref("confirmRenameType") var confirmRenameType: Bool = true
    @Pref("confirmRenameHide") var confirmRenameHide: Bool = true
    @Pref("confirmTerminals") var confirmManyTerminals: Bool = true
    /// Opening an executable file: ask, open in application, or run it.
    @Pref("execAction") var executableAction: ExecutableAction = .ask

    // View › General
    @Pref("perFolder") var rememberPerFolder: Bool = false
    @Pref("selectionMarker") var showSelectionMarker: Bool = true
    @Pref("renameInline") var renameInline: Bool = true
    @Pref("toolTips") var showToolTips: Bool = false
    @Pref("autoExpand") var openFoldersDuringDrag: Bool = false
    @Pref("dblClickBg2") var doubleClickBackground: BackgroundDoubleClick = .selectAll
    @Pref("dynamicView") var dynamicView: Bool = false
    @Pref("browseArchives") var browseArchives: Bool = false
    /// Off: names whose extension is hidden in Finder (Get Info › Hide extension) show without it.
    @Pref("allExtensions") var showAllExtensions: Bool = true
    @Pref("hideBackup") var hideBackupFiles: Bool = false

    // View › Content display
    @Pref("sorting") var sortingChoice: SortingChoice = .natural
    @Pref("folderDepth") var folderSizeDepth: Int = 10
    @Pref("folderSize") var folderSizeMode: FolderSizeMode = .itemCount
    @Pref("dateStyle") var dateStyle: DateStyle = .relative
    @Pref("permStyle") var permissionStyle: PermissionStyle = .symbolic
    @Pref("elideMiddle") var elideMiddle: Bool = true

    // View › Icons / Compact / Details
    @Pref("labelWidth") var iconsLabelWidthIndex: Int = 1
    /// 0 = unlimited.
    @Pref("maxLines") var iconsMaxLines: Int = 3
    /// Compact view maximum label width in average characters; 0 = unlimited.
    @Pref("compactMax") var compactMaxWidth: Int = 0
    /// Details: open by clicking anywhere on the row (Dolphin default) or only on icon/name.
    @Pref("clickRow") var detailsClickAnywhere: Bool = true
    /// Label font: empty = system font.
    @Pref("labelFont") var labelFontName: String = ""
    @Pref("labelFontSize") var labelFontSize: Double = 13.0
    @Pref("expandable") var detailsExpandableFolders: Bool = true
    @Pref("entireRow") var detailsHighlightEntireRow: Bool = true

    // Panels
    @Pref("infoPreview") var infoShowPreview: Bool = true
    @Pref("infoHover") var infoShowHovered: Bool = true
    @Pref("infoAutoPlay") var infoAutoPlay: Bool = false
    @Pref("infoCondensed") var infoCondensedDates: Bool = false
    @Pref("foldersHome") var foldersLimitToHome: Bool = true
    @Pref("foldersHidden") var foldersShowHidden: Bool = false
    @Pref("termFollow") var terminalFollowsDirectory: Bool = true
    @Pref("placesIcon") var placesIconSize: Int = 16

    func contextMenuShows(_ e: ContextMenuEntry) -> Bool { get("ctx." + e.rawValue, e.defaultOn) }
    func setContextMenu(_ e: ContextMenuEntry, _ on: Bool) { set("ctx." + e.rawValue, on) }

    /// Font for item labels (Icons/Compact/Details).
    var labelFont: NSFont {
        let size = CGFloat(labelFontSize)
        if !labelFontName.isEmpty, let f = NSFont(name: labelFontName, size: size) { return f }
        return .systemFont(ofSize: size)
    }

    // Global (common) view properties, used unless per-folder memory is on.
    var globalViewProperties: ViewProperties {
        get {
            guard let data = d.data(forKey: "viewProps"), let p = try? JSONDecoder().decode(ViewProperties.self, from: data) else {
                return ViewProperties()
            }
            return p
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "viewProps") }
    }

    /// The display style for a folder. "Use common display style for all folders": one style everywhere, and a change
    /// made in any folder changes it. "Remember display style for each folder": the folder's own saved style, else the
    /// built-in defaults of special folders (Downloads by date, Trash as details), else the common style.
    func viewProperties(for url: URL) -> ViewProperties {
        guard rememberPerFolder else { return globalViewProperties }
        if let data = d.dictionary(forKey: "folderProps")?[url.path] as? Data,
           let p = try? JSONDecoder().decode(ViewProperties.self, from: data) {
            return p
        }
        let special = ViewProperties.defaults(for: url)
        return special != ViewProperties() ? special : globalViewProperties
    }

    func save(_ props: ViewProperties, for url: URL) {
        if rememberPerFolder {
            var dict = d.dictionary(forKey: "folderProps") ?? [:]
            dict[url.path] = try? JSONEncoder().encode(props)
            d.set(dict, forKey: "folderProps")
        } else {
            globalViewProperties = props
        }
    }

    /// Settings › Restore Defaults: every setting above, the context menu choices and the common view style.
    /// What the app remembers (session, Trash origins, recent places, panel sizes, per-folder view styles) stays.
    func resetAll() {
        let prefKeys = Mirror(reflecting: self).children.compactMap { ($0.value as? PrefKey)?.key }
        let keys = prefKeys + ContextMenuEntry.allCases.map { "ctx." + $0.rawValue } + ["viewProps"]
        keys.forEach(d.removeObject(forKey:))
        NotificationCenter.default.post(name: Settings.changed, object: nil)
    }
}

/// Lets `resetAll()` find the keys of every `@Pref`.
private protocol PrefKey { var key: String { get } }
extension Pref: PrefKey {}
