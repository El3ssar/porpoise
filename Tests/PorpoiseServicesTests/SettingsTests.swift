import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseServices

@Suite(.isolatedSettings) struct SettingsTests {
    let s = Settings.shared

    @Test func defaultsWhenNothingIsStored() {
        #expect(s.startup == .lastSession)
        #expect(s.homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(s.appLibraryView && s.closeButtonsOnTabs && s.confirmDelete && s.showAllExtensions)
        #expect(!s.showFullPathInTitle && !s.confirmTrash && !s.rememberPerFolder && !s.hideBackupFiles)
        #expect(s.tabStyle == .autoSize && s.closeSplitChoice == .active && s.statusBarMode == .fullWidth)
        #expect(s.executableAction == .ask && s.doubleClickBackground == .selectAll)
        #expect(s.sortingChoice == .natural && s.folderSizeMode == .itemCount && s.dateStyle == .relative)
        #expect(s.permissionStyle == .symbolic)
        #expect(s.previewMaxSizeMiB == 100 && s.folderSizeDepth == 10 && s.iconsMaxLines == 3 && s.placesIconSize == 16)
        #expect(s.labelFontName == "" && s.labelFontSize == 13.0)
    }

    @Test func everyKindOfValueRoundTrips() {
        s.showFullPathInTitle = true
        s.previewMaxSizeMiB = 0
        s.labelFontSize = 15.5
        s.labelFontName = "Menlo"
        s.sortingChoice = .caseSensitive
        s.homeURL = URL(fileURLWithPath: "/tmp/elsewhere")
        #expect(s.showFullPathInTitle && s.previewMaxSizeMiB == 0 && s.labelFontSize == 15.5 && s.labelFontName == "Menlo")
        #expect(s.sortingChoice == .caseSensitive)
        #expect(s.homeURL.path == "/tmp/elsewhere")
        // What lands on disk: plain values, enums by raw value, the home folder as a path.
        #expect(Settings.store.object(forKey: "fullPathTitle") as? Bool == true)
        #expect(Settings.store.string(forKey: "sorting") == "caseSensitive")
        #expect(Settings.store.string(forKey: "homeURL") == "/tmp/elsewhere")
    }

    @Test func writesAnnounceTheKey() {
        var keys: [String] = []
        let token = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: nil) { n in
            if let k = n.object as? String { keys.append(k) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        s.dateStyle = .absolute
        s.setContextMenu(.duplicate, false)
        #expect(keys == ["dateStyle", "ctx.duplicate"])
    }

    /// A value of the wrong type or an enum case a later version dropped reads as the default, not as a crash.
    @Test func unreadableStoredValuesFallBackToDefaults() {
        Settings.store.set("not a bool", forKey: "confirmDelete")
        Settings.store.set("sideways", forKey: "statusBar2")
        Settings.store.set(7, forKey: "sorting")
        #expect(s.confirmDelete)
        #expect(s.statusBarMode == .fullWidth)
        #expect(s.sortingChoice == .natural)
    }

    @Test func contextMenuEntries() {
        #expect(!s.contextMenuShows(.deleteAlongsideTrash) && !s.contextMenuShows(.copyMoveTo))
        #expect(s.contextMenuShows(.share) && s.contextMenuShows(.revealInFinder))
        s.setContextMenu(.share, false)
        s.setContextMenu(.copyMoveTo, true)
        #expect(!s.contextMenuShows(.share) && s.contextMenuShows(.copyMoveTo))
        #expect(ContextMenuEntry.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func restoreDefaultsKeepsWhatTheAppRemembers() {
        s.confirmTrash = true
        s.tabStyle = .fullWidth
        s.setContextMenu(.share, false)
        var p = ViewProperties(); p.mode = .details
        s.save(p, for: URL(fileURLWithPath: "/tmp"))
        Settings.store.set(["/tmp"], forKey: "recentLocations")
        Settings.store.set(300.0, forKey: PanelSize.sidebarWidth.rawValue)

        s.resetAll()

        #expect(!s.confirmTrash && s.tabStyle == .autoSize && s.contextMenuShows(.share))
        #expect(s.viewProperties(for: URL(fileURLWithPath: "/tmp")) == ViewProperties())
        #expect(Settings.store.stringArray(forKey: "recentLocations") == ["/tmp"])
        #expect(Settings.store.double(forKey: PanelSize.sidebarWidth.rawValue) == 300)
    }

    // MARK: View properties

    @Test func commonStyleIsSharedByEveryFolder() {
        var p = ViewProperties(); p.mode = .compact; p.sortRole = .size
        s.save(p, for: URL(fileURLWithPath: "/tmp/a"))
        #expect(s.viewProperties(for: URL(fileURLWithPath: "/tmp/b")) == p)
        #expect(Settings.store.dictionary(forKey: "folderProps") == nil)
    }

    @Test func perFolderStylesAreKeptApart() {
        s.rememberPerFolder = true
        var a = ViewProperties(); a.mode = .details
        var b = ViewProperties(); b.showHidden = true
        s.save(a, for: URL(fileURLWithPath: "/tmp/a"))
        s.save(b, for: URL(fileURLWithPath: "/tmp/b"))
        #expect(s.viewProperties(for: URL(fileURLWithPath: "/tmp/a")) == a)
        #expect(s.viewProperties(for: URL(fileURLWithPath: "/tmp/b")) == b)
        // A folder never saved: the common style.
        #expect(s.viewProperties(for: URL(fileURLWithPath: "/tmp/c")) == ViewProperties())
        // Special folders have their own defaults until saved.
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        #expect(s.viewProperties(for: downloads).sortRole == .modificationTime)
    }

    @Test func damagedStoredStyleFallsBackToTheDefaults() {
        Settings.store.set(Data("{oops".utf8), forKey: "viewProps")
        #expect(s.viewProperties(for: URL(fileURLWithPath: "/tmp")) == ViewProperties())
        s.rememberPerFolder = true
        Settings.store.set(["/tmp": Data("[]".utf8)], forKey: "folderProps")
        #expect(s.viewProperties(for: URL(fileURLWithPath: "/tmp")) == ViewProperties())
    }

    // MARK: Panel sizes

    @Test func panelSizesUseDefaultsAndStayWithinLimits() {
        #expect(PanelSize.sidebarWidth.saved(in: 1000) == 160)
        #expect(PanelSize.informationWidth.saved(in: 1000) == 280)
        #expect(PanelSize.terminalHeight.saved(in: 1000) == 220)
        // A window too narrow for the default share: the panel's share, but never under its minimum.
        #expect(PanelSize.sidebarWidth.saved(in: 300) == 135)
        #expect(PanelSize.sidebarWidth.saved(in: 100) == 120)

        PanelSize.sidebarWidth.save(200, in: 1000)
        #expect(PanelSize.sidebarWidth.saved(in: 1000) == 200)
        // Too small, too big or without a window: not kept.
        PanelSize.sidebarWidth.save(50, in: 1000)
        PanelSize.sidebarWidth.save(900, in: 1000)
        PanelSize.sidebarWidth.save(200, in: 0)
        #expect(PanelSize.sidebarWidth.saved(in: 1000) == 200)
        // A remembered size too big for a smaller window gives way.
        #expect(PanelSize.sidebarWidth.saved(in: 400) == 160)
    }

    @Test func fittedSizesLeaveRoomForTheFiles() {
        #expect(PanelSize.informationWidth.fitted(in: 1000, divider: 1) == 280)
        // 500 points: the files keep 280, the panel gets the rest down to its minimum.
        #expect(PanelSize.informationWidth.fitted(in: 500, divider: 0) == 220)
        #expect(PanelSize.informationWidth.fitted(in: 300, divider: 0) == 135)
        #expect(PanelSize.terminalHeight.fitted(in: 300, divider: 0) == 150)
    }

    @Test func dividerRanges() {
        #expect(PanelSize.sidebarWidth.dividerRange(in: 1000, divider: 1) == 120...450)
        // Panels after the files: the divider sits at the files' extent.
        #expect(PanelSize.informationWidth.dividerRange(in: 1000, divider: 1) == 549...799)
        #expect(PanelSize.terminalHeight.dividerRange(in: 600, divider: 0) == 180...520)
    }

    // MARK: Recent locations

    @Test func recentLocationsKeepTheLatestFortyOnce() {
        let recent = RecentLocations()
        for i in 0..<45 { recent.visit(URL(fileURLWithPath: "/tmp/\(i)")) }
        recent.visit(URL(fileURLWithPath: "/tmp/10"))
        recent.visit(URL(string: "sftp://host/x")!)  // only local folders
        #expect(recent.urls.count == 40)
        #expect(recent.urls.first?.path == "/tmp/10" && recent.urls[1].path == "/tmp/44")
        #expect(recent.urls.filter { $0.path == "/tmp/10" }.count == 1)
        #expect(RecentLocations().urls == recent.urls)  // read back from the store
    }

    // MARK: Migration from the old name

    @Test func migrationCopiesOldSettingsAndPlacesOnce() throws {
        let scratch = try Scratch()
        // The old app's settings file. A domain named by a path is read from that file; it is only read here, so
        // nothing is written outside the throwaway folder.
        let oldSettings: [String: Any] = ["fullPathTitle": true, "sorting": "details", "NSWindow Frame Main": "{{0, 0}, {10, 10}}"]
        try PropertyListSerialization.data(fromPropertyList: oldSettings, format: .binary, options: 0)
            .write(to: scratch.path("old-defaults.plist"))
        let oldDomain = scratch.path("old-defaults").path
        Settings.store.set("natural", forKey: "sorting")  // already set here: stays
        let oldPlaces = try scratch.file("Dolphin/places.json", "[old]")
        let newPlaces = scratch.path("Porpoise/places.json")

        Migration.run(from: oldDomain, into: Settings.store, oldPlaces: oldPlaces, newPlaces: newPlaces)

        #expect(Settings.store.bool(forKey: "fullPathTitle"))
        #expect(Settings.store.string(forKey: "sorting") == "natural")
        #expect(Settings.store.object(forKey: "NSWindow Frame Main") == nil)
        #expect(scratch.read("Porpoise/places.json") == "[old]")

        // Once only: later changes to the old app's settings are not copied again.
        Settings.store.removeObject(forKey: "fullPathTitle")
        try Data("[newer]".utf8).write(to: oldPlaces)
        try FileManager.default.removeItem(at: newPlaces)
        Migration.run(from: oldDomain, into: Settings.store, oldPlaces: oldPlaces, newPlaces: newPlaces)
        #expect(Settings.store.object(forKey: "fullPathTitle") == nil)
        #expect(!FileManager.default.fileExists(atPath: newPlaces.path))
    }

    @Test func migrationNeverReplacesExistingPlaces() throws {
        let scratch = try Scratch()
        let oldPlaces = try scratch.file("Dolphin/places.json", "[old]")
        let newPlaces = try scratch.file("Porpoise/places.json", "[mine]")
        Migration.run(from: scratch.path("missing").path, into: Settings.store, oldPlaces: oldPlaces, newPlaces: newPlaces)
        #expect(scratch.read("Porpoise/places.json") == "[mine]")
        #expect(Settings.store.bool(forKey: "migratedFromDolphin"))
    }

    @Test func migrationIsSkippedInTestInstances() {
        Migration.run()
        #expect(Settings.store.object(forKey: "migratedFromDolphin") == nil)
    }
}

/// The raw values are what users' settings files hold: renaming a case loses everyone's choice.
@Suite struct StoredRawValueTests {
    @Test func settingsEnums() {
        #expect(StatusBarMode.allCases.map(\.rawValue) == ["small", "fullWidth", "disabled"])
        #expect(TabStyle.allCases.map(\.rawValue) == ["autoSize", "fixedSize", "fullWidth"])
        #expect(CloseSplitChoice.allCases.map(\.rawValue) == ["active", "inactive", "right"])
        #expect(FolderSizeMode.allCases.map(\.rawValue) == ["itemCount", "contentSize", "none"])
        #expect(DateStyle.allCases.map(\.rawValue) == ["relative", "absolute"])
        #expect(PermissionStyle.allCases.map(\.rawValue) == ["symbolic", "numeric", "combined"])
        #expect(StartupLocation.allCases.map(\.rawValue) == ["lastSession", "home"])
        #expect(ExecutableAction.allCases.map(\.rawValue) == ["ask", "open", "run"])
        #expect(
            BackgroundDoubleClick.allCases.map(\.rawValue)
                == ["nothing", "selectAll", "goUp", "newFolder", "toggleHidden", "openTerminal"])
        #expect(BackgroundDoubleClick.allCases.map(\.title).allSatisfy { !$0.isEmpty })
        #expect(
            ContextMenuEntry.allCases.map(\.rawValue) == [
                "addToPlaces", "copyLocation", "duplicate", "openInNewTab", "openInNewWindow", "openInSplit", "openTerminal",
                "otherView", "sortBy", "viewMode", "deleteAlongsideTrash", "copyMoveTo", "compress", "tags", "share",
                "quickLook", "revealInFinder",
            ])
        #expect(
            PanelSize.sidebarWidth.rawValue == "width.left" && PanelSize.informationWidth.rawValue == "width.right"
                && PanelSize.terminalHeight.rawValue == "height.terminal")
    }

    @Test func viewEnums() {
        #expect(ViewMode.allCases.map(\.rawValue) == ["icons", "compact", "details"])
        #expect(
            ItemRole.allCases.map(\.rawValue) == [
                "name", "size", "modificationTime", "creationTime", "accessTime", "type", "path", "extension_", "permissions",
                "owner", "group", "linkDestination", "tags",
            ])
        #expect(SortOrder.ascending.rawValue == "ascending" && SortOrder.descending.rawValue == "descending")
        #expect(SortingChoice.allCases.map(\.rawValue) == ["natural", "caseInsensitive", "caseSensitive"])
        #expect(FilterMode.allCases.map(\.rawValue) == ["plainText", "glob", "regex"])
    }

    @Test func placesSections() {
        #expect(PlaceSection.allCases.map(\.rawValue) == ["Places", "Remote", "Recent", "Tags", "Devices", "Removable Devices"])
    }

    /// Every @Pref key, as found on users' disks.
    @Test func prefKeys() {
        let keys = Mirror(reflecting: Settings.shared).children.compactMap { ($0.value as? PrefKey)?.key }
        #expect(
            keys == [
                "startup", "homeURL", "fullPathTitle", "appLibraryView", "filterBar", "alwaysTabBar", "tabClose", "tabStyle",
                "tabsAtEnd", "closeSplit", "splitStartup", "singleWindow", "pvImages", "pvVideos", "pvDocs", "pvText", "pvFonts",
                "pvFolders", "pvMax", "pvRemote", "statusBar2", "zoomSlider2", "editableUrl", "fullPathUrl", "confirmTrash",
                "confirmDelete", "confirmEmptyTrash", "confirmCloseTabs", "confirmTerminal", "confirmOpenMany",
                "confirmRenameType", "confirmRenameHide", "confirmTerminals", "execAction", "perFolder", "selectionMarker",
                "renameInline", "toolTips", "autoExpand", "dblClickBg2", "dynamicView", "browseArchives", "allExtensions",
                "hideBackup", "sorting", "folderDepth", "folderSize", "dateStyle", "permStyle", "elideMiddle", "labelWidth",
                "maxLines", "compactMax", "clickRow", "labelFont", "labelFontSize", "expandable", "entireRow", "infoPreview",
                "infoHover", "infoAutoPlay", "infoCondensed", "foldersHome", "foldersHidden", "termFollow", "placesIcon",
            ])
    }
}
