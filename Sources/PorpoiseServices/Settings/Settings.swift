import Foundation
import PorpoiseCore

/// Global settings, stored in UserDefaults (Dolphin's dolphinrc equivalent).
/// Keys and defaults are part of the users' saved settings: never change them.
public final class Settings {
    public static let shared = Settings()
    public static let changed = Notification.Name("PorpoiseSettingsChanged")
    /// Test instances set PORPOISE_DEFAULTS_SUITE to use a throwaway defaults domain.
    private static let testSuite = ProcessInfo.processInfo.environment["PORPOISE_DEFAULTS_SUITE"]
    /// UserDefaults for everything the app stores. Tests may replace it (and set `isTesting`) before first use.
    nonisolated(unsafe) public static var store: UserDefaults = testSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    /// A test run: nothing is written outside `store`, and the system (sounds, helper, Trash) is left alone.
    nonisolated(unsafe) public static var isTesting: Bool = testSuite != nil
    private var d: UserDefaults { Settings.store }

    private func get<T>(_ key: String, _ def: T) -> T { (d.object(forKey: key) as? T) ?? def }
    private func set(_ key: String, _ v: Any?) {
        d.set(v, forKey: key)
        NotificationCenter.default.post(name: Settings.changed, object: key)
    }

    // Interface › Folders & Tabs
    @Pref("startup") public var startup: StartupLocation = .lastSession
    /// Stored as a path.
    @Pref("homeURL") private var homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    public var homeURL: URL {
        get { URL(fileURLWithPath: homePath) }
        set { homePath = newValue.path }
    }
    @Pref("fullPathTitle") public var showFullPathInTitle: Bool = false
    /// Applications as an app library (big icons, search) instead of a regular folder view.
    @Pref("appLibraryView") public var appLibraryView: Bool = true
    @Pref("filterBar") public var showFilterBarOnStartup: Bool = false
    @Pref("alwaysTabBar") public var alwaysShowTabBar: Bool = false
    @Pref("tabClose") public var closeButtonsOnTabs: Bool = true
    @Pref("tabStyle") public var tabStyle: TabStyle = .autoSize
    @Pref("tabsAtEnd") public var openNewTabsAtEnd: Bool = false
    @Pref("closeSplit") public var closeSplitChoice: CloseSplitChoice = .active
    @Pref("splitStartup") public var splitViewOnStartup: Bool = false

    @Pref("singleWindow") public var singleWindow: Bool = false

    // Interface › Previews
    @Pref("pvImages") public var previewImages: Bool = true
    @Pref("pvVideos") public var previewVideos: Bool = true
    @Pref("pvDocs") public var previewDocuments: Bool = true
    @Pref("pvText") public var previewText: Bool = false
    @Pref("pvFonts") public var previewFonts: Bool = true
    @Pref("pvFolders") public var previewFolders: Bool = false
    /// Local files larger than this (MiB) get no preview; 0 = no limit.
    @Pref("pvMax") public var previewMaxSizeMiB: Int = 100
    @Pref("pvRemote") public var previewRemote: Bool = false

    // Interface › Status & Location bars
    @Pref("statusBar2") public var statusBarMode: StatusBarMode = .fullWidth
    @Pref("zoomSlider2") public var showZoomSlider: Bool = true
    @Pref("editableUrl") public var editableLocation: Bool = false
    @Pref("fullPathUrl") public var showFullPathInLocation: Bool = false

    // Interface › Confirmations
    @Pref("confirmTrash") public var confirmTrash: Bool = false
    @Pref("confirmDelete") public var confirmDelete: Bool = true
    @Pref("confirmEmptyTrash") public var confirmEmptyTrash: Bool = true
    @Pref("confirmCloseTabs") public var confirmCloseTabs: Bool = true
    @Pref("confirmTerminal") public var confirmCloseTerminal: Bool = true
    @Pref("confirmOpenMany") public var confirmOpenMany: Bool = true
    @Pref("confirmRenameType") public var confirmRenameType: Bool = true
    @Pref("confirmRenameHide") public var confirmRenameHide: Bool = true
    @Pref("confirmTerminals") public var confirmManyTerminals: Bool = true
    /// Opening an executable file: ask, open in application, or run it.
    @Pref("execAction") public var executableAction: ExecutableAction = .ask

    // View › General
    @Pref("perFolder") public var rememberPerFolder: Bool = false
    @Pref("selectionMarker") public var showSelectionMarker: Bool = true
    @Pref("renameInline") public var renameInline: Bool = true
    @Pref("toolTips") public var showToolTips: Bool = false
    @Pref("autoExpand") public var openFoldersDuringDrag: Bool = false
    @Pref("dblClickBg2") public var doubleClickBackground: BackgroundDoubleClick = .selectAll
    @Pref("dynamicView") public var dynamicView: Bool = false
    @Pref("browseArchives") public var browseArchives: Bool = false
    /// Off: names whose extension is hidden in Finder (Get Info › Hide extension) show without it.
    @Pref("allExtensions") public var showAllExtensions: Bool = true
    @Pref("hideBackup") public var hideBackupFiles: Bool = false

    // View › Content display
    @Pref("sorting") public var sortingChoice: SortingChoice = .natural
    @Pref("folderDepth") public var folderSizeDepth: Int = 10
    @Pref("folderSize") public var folderSizeMode: FolderSizeMode = .itemCount
    @Pref("dateStyle") public var dateStyle: DateStyle = .relative
    @Pref("permStyle") public var permissionStyle: PermissionStyle = .symbolic
    @Pref("elideMiddle") public var elideMiddle: Bool = true

    // View › Icons / Compact / Details
    @Pref("labelWidth") public var iconsLabelWidthIndex: Int = 1
    /// 0 = unlimited.
    @Pref("maxLines") public var iconsMaxLines: Int = 3
    /// Compact view maximum label width in average characters; 0 = unlimited.
    @Pref("compactMax") public var compactMaxWidth: Int = 0
    /// Details: open by clicking anywhere on the row (Dolphin default) or only on icon/name.
    @Pref("clickRow") public var detailsClickAnywhere: Bool = true
    /// Label font: empty = system font.
    @Pref("labelFont") public var labelFontName: String = ""
    @Pref("labelFontSize") public var labelFontSize: Double = 13.0
    @Pref("expandable") public var detailsExpandableFolders: Bool = true
    @Pref("entireRow") public var detailsHighlightEntireRow: Bool = true

    // Panels
    @Pref("infoPreview") public var infoShowPreview: Bool = true
    @Pref("infoHover") public var infoShowHovered: Bool = true
    @Pref("infoAutoPlay") public var infoAutoPlay: Bool = false
    @Pref("infoCondensed") public var infoCondensedDates: Bool = false
    @Pref("foldersHome") public var foldersLimitToHome: Bool = true
    @Pref("foldersHidden") public var foldersShowHidden: Bool = false
    @Pref("termFollow") public var terminalFollowsDirectory: Bool = true
    @Pref("placesIcon") public var placesIconSize: Int = 16

    public func contextMenuShows(_ e: ContextMenuEntry) -> Bool { get("ctx." + e.rawValue, e.defaultOn) }
    public func setContextMenu(_ e: ContextMenuEntry, _ on: Bool) { set("ctx." + e.rawValue, on) }

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
            let p = try? JSONDecoder().decode(ViewProperties.self, from: data)
        {
            return p
        }
        let special = ViewProperties.defaults(for: url)
        return special != ViewProperties() ? special : globalViewProperties
    }

    public func save(_ props: ViewProperties, for url: URL) {
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
    public func resetAll() {
        let prefKeys = Mirror(reflecting: self).children.compactMap { ($0.value as? PrefKey)?.key }
        let keys = prefKeys + ContextMenuEntry.allCases.map { "ctx." + $0.rawValue } + ["viewProps"]
        keys.forEach(d.removeObject(forKey:))
        NotificationCenter.default.post(name: Settings.changed, object: nil)
    }
}
