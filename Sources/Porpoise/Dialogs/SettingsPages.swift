import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

/// The Settings window's pages, grouped by what a Mac user looks for: General, Appearance, Views, Sidebar & Bars,
/// Files, Accounts & Servers, Keyboard and Advanced. Every setting keeps its stored key, whatever page it is on.
@MainActor enum SettingsPages {
    /// The pages, in toolbar order: title, SF Symbol, builder.
    static let all: [(title: String, symbol: String, build: (FormBuilder) -> Void)] = [
        ("General", "gearshape", general),
        ("Appearance", "paintpalette", { AppearancePage.build($0) }),
        ("Views", "square.grid.2x2", views),
        ("Sidebar & Bars", "sidebar.left", sidebarAndBars),
        ("Files", "doc.on.doc", files),
        (accountsAndServers, "person.crop.circle", AccountsSettingsPage.build),
        ("Keyboard", "keyboard", keyboard),
        ("Advanced", "gearshape.2", advanced),
    ]

    nonisolated static let accountsAndServers = "Accounts & Servers"

    /// Where the pages of earlier versions went: a page shown last, or asked for by its old name, opens here.
    nonisolated static let renamed: [String: String] = [
        "View": "Views", "Panels": "Sidebar & Bars", "Bars & Panels": "Sidebar & Bars", "Activity": "Files", "Accounts": accountsAndServers,
        "Shortcuts": "Keyboard", "Custom Tools": "Keyboard", "Terminal": "Advanced", "Search": "Advanced",
    ]

    /// The page that shows `name`: itself, or the page an old one went to.
    static func page(named name: String) -> String? {
        if all.contains(where: { $0.title == name }) { return name }
        return renamed[name]
    }

    private static var s: Settings { .shared }

    static func general(_ f: FormBuilder) {
        f.section("Show on startup")
        f.radio(["Folders, tabs, and window state from last time", "The home location below"], s.startup == .lastSession ? 0 : 1) {
            s.startup = $0 == 0 ? .lastSession : .home
        }
        f.text("Home location:", s.homeURL.path) { [weak f] text in
            // Only an existing folder: a mistyped path would break Home, new tabs and new windows.
            var isDir: ObjCBool = false
            let path = (text as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                s.homeURL = URL(fileURLWithPath: path)
            } else {
                NSSound.beep()
                f?.refresh()  // back to the saved location
            }
        }
        f.button("Use Current Location") {
            // The frontmost Porpoise window (this Settings window is the main window while it is open).
            let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? MainWindowController }.first
            if let u = front?.view.url, u.isFileURL { s.homeURL = u } else { NSSound.beep() }
        }
        f.button("Use Default Location") { s.homeURL = FileManager.default.homeDirectoryForCurrentUser }
        f.section("Windows")
        f.check("Keep a single Porpoise window, opening new folders in tabs", s.singleWindow) { s.singleWindow = $0 }
        // Light or dark is chosen once, on the Appearance page, beside the theme it applies to.
        f.check("Show full path in window title", s.showFullPathInTitle) { s.showFullPathInTitle = $0 }
        f.note(
            "The window title appears in the Window menu, Mission Control and the Dock's window list (the toolbar takes the title bar's place).")
        f.section("Tabs")
        f.check("Always show tab bar", s.alwaysShowTabBar) { s.alwaysShowTabBar = $0 }
        f.check("Show close button on tabs", s.closeButtonsOnTabs) { s.closeButtonsOnTabs = $0 }
        f.popup("Tab width:", ["Adapt to folder name", "Fixed width", "Span available width"], TabStyle.allCases.firstIndex(of: s.tabStyle) ?? 0) {
            s.tabStyle = TabStyle.allCases[$0]
        }
        f.popup("Open new tabs:", ["After current tab", "At end of tab bar"], s.openNewTabsAtEnd ? 1 : 0) { s.openNewTabsAtEnd = $0 == 1 }
        f.section("Split view")
        f.popup(
            "When closing:", ["Close the active pane", "Close the inactive pane", "Always close the right pane"],
            CloseSplitChoice.allCases.firstIndex(of: s.closeSplitChoice) ?? 0
        ) { s.closeSplitChoice = CloseSplitChoice.allCases[$0] }
        f.check("Open new windows in split view mode", s.splitViewOnStartup) { s.splitViewOnStartup = $0 }
        defaultFileBrowser(f)
        f.section("Updates")
        let u = Updates.shared
        f.check("Check for updates automatically (once a day)", u.automaticallyChecks, enabled: { u.isAvailable }) { u.automaticallyChecks = $0 }
        f.check(
            "Download and install updates automatically", u.automaticallyInstalls,
            enabled: { u.isAvailable && u.automaticallyChecks }
        ) { u.automaticallyInstalls = $0 }
        f.button("Check Now") { u.checkForUpdates(nil) }
    }

    private static func defaultFileBrowser(_ f: FormBuilder) {
        f.section("Default file browser")
        f.note(
            "Open Porpoise instead of Finder when other apps show a file (“Show in Finder”, “Reveal in Finder”, a download’s magnifying glass). macOS keeps the desktop, and opening folders from the Dock, with Finder."
        )
        f.status(
            "Status:",
            {
                guard SystemIntegration.isDefaultBrowser else { return (false, "Finder shows files for other apps") }
                return (
                    true,
                    SystemIntegration.opensFolders
                        ? "Porpoise shows files and opens folders for other apps"
                        : SystemIntegration.opensDisks
                            ? "Porpoise shows files and opens disks for other apps (macOS keeps folders with Finder)"
                            : "Porpoise shows files for other apps (macOS keeps folders with Finder)"
                )
            }, button: { SystemIntegration.isDefaultBrowser ? "Restore Finder" : "Make Porpoise Default" }
        ) { refresh in
            SystemIntegration.setDefaultBrowser(!SystemIntegration.isDefaultBrowser) { err in
                if let err { NSAlert(error: err).runSheet(for: SettingsWindowController.window) { _ in } }
                refresh()
            }
        }
    }

    static func views(_ f: FormBuilder) {
        f.section("Display style")
        f.radio(["Use common display style for all folders", "Remember display style for each folder"], s.rememberPerFolder ? 1 : 0) {
            s.rememberPerFolder = $0 == 1
        }
        // Only with the common style: a folder's remembered style always wins.
        f.check(
            "Use Icons for folders that hold mostly photos and videos", s.dynamicView,
            enabled: { !s.rememberPerFolder }
        ) { s.dynamicView = $0 }
        f.check("Show Applications as an app library", s.appLibraryView) { s.appLibraryView = $0 }
        f.note("Icon size: use the slider in the status bar, pinch, or ⌘+/⌘− in each view.")
        f.section("Browsing")
        f.check("Open folders during drag operations", s.openFoldersDuringDrag) { s.openFoldersDuringDrag = $0 }
        f.popup(
            "Double-click on empty space:", BackgroundDoubleClick.allCases.map(\.title),
            BackgroundDoubleClick.allCases.firstIndex(of: s.doubleClickBackground) ?? 1
        ) { s.doubleClickBackground = BackgroundDoubleClick.allCases[$0] }
        f.section("Items")
        f.check("Show item information on hover", s.showToolTips) { s.showToolTips = $0 }
        f.check("Show selection marker", s.showSelectionMarker) { s.showSelectionMarker = $0 }
        f.check("Rename single items inline", s.renameInline) { s.renameInline = $0 }
        f.check("Also hide backup files while hiding hidden files", s.hideBackupFiles) { s.hideBackupFiles = $0 }
        f.check("Always show file extensions", s.showAllExtensions) { s.showAllExtensions = $0 }
        f.note("When off, files are shown without their extension (“report” instead of “report.pdf”). Renaming still shows the full name.")
        f.section("Content display")
        f.check("Binary units (KiB)", s.binaryUnits) { s.binaryUnits = $0 }
        f.popup("Sort names:", SortingChoice.allCases.map(\.title), SortingChoice.allCases.firstIndex(of: s.sortingChoice) ?? 0) {
            s.sortingChoice = SortingChoice.allCases[$0]
        }
        f.popup(
            "Folder size:", ["Show number of items", "Show size of contents", "Show no size"],
            FolderSizeMode.allCases.firstIndex(of: s.folderSizeMode) ?? 0
        ) { s.folderSizeMode = FolderSizeMode.allCases[$0] }
        f.stepper(
            "Size of contents, up to:", s.folderSizeDepth, 1...30, suffix: "levels deep",
            enabled: { s.folderSizeMode == .contentSize }
        ) { s.folderSizeDepth = $0 }
        f.popup("Date style:", ["Relative (e.g. 'Yesterday at 14:00')", "Absolute"], s.dateStyle == .relative ? 0 : 1) {
            s.dateStyle = $0 == 0 ? .relative : .absolute
        }
        f.popup(
            "Permissions:", ["Symbolic (drwxr-xr-x)", "Numeric (755)", "Combined"],
            PermissionStyle.allCases.firstIndex(of: s.permissionStyle) ?? 0
        ) { s.permissionStyle = PermissionStyle.allCases[$0] }
        f.popup("Long file names:", ["Elide in the middle", "Elide at the end"], s.elideMiddle ? 0 : 1) { s.elideMiddle = $0 == 0 }
        f.section("Icons")
        f.popup("Label width:", ["Small", "Medium", "Large", "Huge"], s.iconsLabelWidthIndex) { s.iconsLabelWidthIndex = $0 }
        f.popup("Maximum lines:", ["Unlimited", "1", "2", "3", "4", "5"], max(0, s.iconsMaxLines)) { s.iconsMaxLines = $0 }
        f.section("Compact")
        f.popup("Maximum width:", ["Automatic", "Small", "Medium", "Large", "Huge"], [0, 10, 20, 30, 45].firstIndex(of: s.compactMaxWidth) ?? 0) {
            s.compactMaxWidth = [0, 10, 20, 30, 45][$0]
        }
        f.section("Details")
        f.check("Expandable folders", s.detailsExpandableFolders) { s.detailsExpandableFolders = $0 }
        f.check("Highlight entire row", s.detailsHighlightEntireRow) { s.detailsHighlightEntireRow = $0 }
        f.radio(
            ["Open files and folders by clicking anywhere on the row", "Open files and folders by clicking on the icon or name"],
            s.detailsClickAnywhere ? 0 : 1
        ) { s.detailsClickAnywhere = $0 == 0 }
        f.section("Show previews for")
        f.check("Images", s.previewImages) { s.previewImages = $0 }
        f.check("Videos", s.previewVideos) { s.previewVideos = $0 }
        f.check("PDFs and documents", s.previewDocuments) { s.previewDocuments = $0 }
        f.check("Text files", s.previewText) { s.previewText = $0 }
        f.check("Fonts", s.previewFonts) { s.previewFonts = $0 }
        f.check("Folders (show their contents)", s.previewFolders) { s.previewFolders = $0 }
        f.section("Preview size limits")
        f.stepper("Local files below:", s.previewMaxSizeMiB, 0...10000, suffix: "MiB (0 = no limit)") { s.previewMaxSizeMiB = $0 }
        f.check("Show previews for remote files", s.previewRemote) { s.previewRemote = $0 }
    }

    static func sidebarAndBars(_ f: FormBuilder) {
        f.section("Folders panel")
        f.check("Limit to Home folder", s.foldersLimitToHome) { s.foldersLimitToHome = $0 }
        f.check("Show hidden folders", s.foldersShowHidden) { s.foldersShowHidden = $0 }
        f.section("Information panel")
        f.check("Show preview", s.infoShowPreview) { s.infoShowPreview = $0 }
        f.check("Auto-play media files", s.infoAutoPlay, enabled: { s.infoShowPreview }) { s.infoAutoPlay = $0 }
        f.check("Show item on hover", s.infoShowHovered) { s.infoShowHovered = $0 }
        // Examples in the user's own date format, as the panel will show them.
        let yesterday = Date().addingTimeInterval(-86_400)
        let short = DateFormatter.localizedString(from: yesterday, dateStyle: .short, timeStyle: .short)
        f.popup("Dates:", ["Relative (\(FileFormat.relativeDate(yesterday)))", "Short (\(short))"], s.infoCondensedDates ? 1 : 0) {
            s.infoCondensedDates = $0 == 1
        }
        f.section("Status bar")
        f.popup("Style:", ["Small", "Full width", "Hidden"], StatusBarMode.allCases.firstIndex(of: s.statusBarMode) ?? 1) {
            s.statusBarMode = StatusBarMode.allCases[$0]
        }
        // The small status bar has no room for it (Dolphin shows it in the full-width bar only).
        f.check("Show Git status in local folders", s.showGitStatus) { s.showGitStatus = $0 }
        f.check("Show zoom slider", s.showZoomSlider, enabled: { s.statusBarMode == .fullWidth }) { s.showZoomSlider = $0 }
        f.section("Location bar")
        f.check("Make location bar editable", s.editableLocation) { s.editableLocation = $0 }
        f.check("Show full path inside location bar", s.showFullPathInLocation) { s.showFullPathInLocation = $0 }
        f.section("Filter bar")
        f.check("Always show filter bar", s.showFilterBarOnStartup) { s.showFilterBarOnStartup = $0 }
        f.section("Show in context menus")
        for e in ContextMenuEntry.allCases {
            f.check(e.title, s.contextMenuShows(e)) { s.setContextMenu(e, $0) }
        }
    }

    static func files(_ f: FormBuilder) {
        f.section("Ask for confirmation when")
        f.check("Moving files or folders to the Trash", s.confirmTrash) { s.confirmTrash = $0 }
        f.check("Deleting files or folders", s.confirmDelete) { s.confirmDelete = $0 }
        f.check("Emptying the Trash", s.confirmEmptyTrash) { s.confirmEmptyTrash = $0 }
        f.check("Renaming changes a file's type", s.confirmRenameType) { s.confirmRenameType = $0 }
        f.check("Renaming hides an item", s.confirmRenameHide) { s.confirmRenameHide = $0 }
        f.check("Closing windows with multiple tabs", s.confirmCloseTabs) { s.confirmCloseTabs = $0 }
        f.check("Closing with a program running in the Terminal panel", s.confirmCloseTerminal) { s.confirmCloseTerminal = $0 }
        f.check("Opening many folders or files at once", s.confirmOpenMany) { s.confirmOpenMany = $0 }
        f.check("Opening many terminals at once", s.confirmManyTerminals) { s.confirmManyTerminals = $0 }
        f.popup(
            "When opening an executable file:", ["Always ask", "Open in application", "Run script"],
            ExecutableAction.allCases.firstIndex(of: s.executableAction) ?? 0
        ) { s.executableAction = ExecutableAction.allCases[$0] }
        trash(f)
        TransferSettingsPage.build(f)
        f.section("Name clashes")
        let rules: [TransferConflictRule] = [.ask, .different, .newer, .keepBoth, .skip]
        f.popup("When names clash:", rules.map(\.title), rules.firstIndex(of: s.transferConflictRule) ?? 0) { s.transferConflictRule = rules[$0] }
        let methods: [TransferCompareMethod] = [.sizeAndDate, .sizeOnly, .content]
        f.popup(
            "Compare using:", ["Size & date (2 second tolerance)", "Size only", "Contents"], methods.firstIndex(of: s.transferCompareMethod) ?? 0
        ) { s.transferCompareMethod = methods[$0] }
        f.note("Copy, move, paste and drop use this comparison when resolving name clashes.")
        f.section("Archives")
        f.check("Browse compressed files as folders", s.browseArchives) { s.browseArchives = $0 }
        compareFiles(f)
    }

    /// Watches ~/.Trash while the Settings window exists.
    private static var trashWatcher: FolderWatcher?

    private static func trash(_ f: FormBuilder) {
        f.section("Trash")
        // Sizing the Trash walks every item in it: done in the background.
        // Kept current: re-read whenever the Trash changes (emptied, items trashed from anywhere).
        let summary = f.note("Calculating…")
        let form = WeakForm(f)
        let refresh = {
            DispatchQueue.global(qos: .utility).async {
                let text = TrashInfo.summary()
                DispatchQueue.main.async {
                    summary.stringValue = text; form.builder?.refresh()
                }
            }
        }
        refresh()
        trashWatcher = FolderWatcher { _ in refresh() }
        trashWatcher?.watch([TrashInfo.folder])
        f.check("Remove items from the Trash after 30 days (Finder setting)", TrashInfo.autoEmpty) { TrashInfo.autoEmpty = $0 }
        f.check("Review an app's leftover files when it's moved to the Trash", s.reviewAppLeftovers) { s.reviewAppLeftovers = $0 }
        f.button("Empty Trash…", enabled: { !TrashInfo.isEmpty }) {
            FileOperationsController.shared.emptyTrash(window: SettingsWindowController.window)
        }
    }

    private static func compareFiles(_ f: FormBuilder) {
        f.section("Compare files")
        f.status(
            "Default compare app:",
            {
                let path = Settings.store.string(forKey: "fileDiff.defaultApp")
                return (nil, path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Porpoise")
            }, button: { "Choose App…" }
        ) { refresh in
            FileDiffExternalTools.chooseDefault(window: SettingsWindowController.window, done: refresh)
        }
        f.button("Use Porpoise for File Comparison") {
            Settings.store.removeObject(forKey: "fileDiff.defaultApp")
            NotificationCenter.default.post(name: Settings.changed, object: "fileDiff.defaultApp")
        }
    }

    static func keyboard(_ f: FormBuilder) {
        ShortcutSettingsPage.build(f)
        CustomToolsSettingsPage.build(f)
    }

    static func advanced(_ f: FormBuilder) {
        TerminalSettingsPage.build(f)
        IndexSettingsPage.build(f)
        CLIAutomationSettings.build(f)
        HelperSettings.build(f)
        androidPhones(f)
        permissions(f)
        f.section("Reset")
        f.button("Restore All Defaults") {
            let a = NSAlert()
            a.messageText = "Restore all Porpoise settings to their defaults?"
            a.informativeText = "Places, open tabs and the view styles saved for single folders are kept."
            a.addButton(withTitle: "Restore Defaults")
            a.addButton(withTitle: "Cancel")
            a.runSheet(for: SettingsWindowController.window) { r in
                guard r == .alertFirstButtonReturn else { return }
                Settings.shared.resetAll()  // every control re-reads its value
            }
        }
    }

    private static func androidPhones(_ f: FormBuilder) {
        f.section("Android phones")
        f.note(
            "Browsing Android phones over USB uses Google's adb tool. Porpoise downloads it from Google (about 15 MB) when you ask; Google's license doesn't allow including it."
        )
        f.status(
            "Android support:",
            {
                AndroidTools.isInstalled
                    ? (true, "Installed. Connect a phone with USB debugging on; it appears under Removable Devices.")
                    : (nil, "Not installed.")
            }, button: { AndroidTools.isInstalled ? "Installed" : "Install Android Support" }
        ) { refresh in
            guard !AndroidTools.isInstalled else { return }
            AndroidTools.install { err in
                if let err {
                    let a = NSAlert()
                    a.messageText = "Android support could not be installed"
                    a.informativeText = err
                    a.runModal()
                }
                PlacesModel.shared.refreshDetected()
                refresh()
            }
        }
    }

    nonisolated static let permissionsSection = "Permissions"

    private static func permissions(_ f: FormBuilder) {
        f.section(permissionsSection)
        f.note("macOS keeps these in System Settings › Privacy & Security. Changes take effect the next time Porpoise starts.")
        // Find out once whether App Management is in effect (silent unless macOS reports a denial).
        if PrivacyAccess.appManagementState == .unknown { SystemIntegration.checkAppManagementInBackground() }
        for perm in SystemIntegration.permissions {
            f.status(
                perm.title + ":", perm.status,
                button: {
                    // Granted: just a link. Otherwise the request button when there is one.
                    guard perm.status().0 != true, let request = perm.request else { return "Open Settings…" }
                    return request.title
                }
            ) { refresh in
                if perm.status().0 != true, let r = perm.request {
                    r.run()
                } else if let open = perm.open {
                    open()
                } else {
                    SystemIntegration.openPrivacyPane(perm.anchor)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh() }
            }
        }
    }
}

/// A page's builder, held weakly where a background job reports back on the main thread.
@MainActor private final class WeakForm {
    weak var builder: FormBuilder?
    init(_ builder: FormBuilder) { self.builder = builder }
}
