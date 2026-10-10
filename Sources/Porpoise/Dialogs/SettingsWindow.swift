import AppKit
import PorpoiseCore
import PorpoiseServices

/// "Configure Dolphin" as a native Mac settings window, with Dolphin's pages and options.
final class SettingsWindowController: NSWindowController {
    /// The Settings window, for the pages' sheets (whichever window happens to be key).
    private(set) static weak var window: NSWindow?

    /// The pages' builders, kept so their observers live (and are removed) with the window.
    private var builders: [FormBuilder] = []
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        var builders: [FormBuilder] = []
        func page(_ title: String, _ symbol: String, _ build: (FormBuilder) -> Void) {
            let vc = NSViewController()
            let fb = FormBuilder()
            builders.append(fb)
            build(fb)
            // Long pages scroll, like KDE's settings pages.
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 760, height: 580))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            let doc = FlippedView()
            doc.addSubview(fb.view)
            fb.view.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = doc
            doc.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                fb.view.topAnchor.constraint(equalTo: doc.topAnchor),
                fb.view.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                fb.view.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                fb.view.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            ])
            vc.view = scroll
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let s = Settings.shared

        page("Folders & Tabs", "folder") { f in
            f.section("Show on startup")
            f.radio(["Folders, tabs, and window state from last time", "Home location"], s.startup == .lastSession ? 0 : 1) { s.startup = $0 == 0 ? .lastSession : .home }
            f.text("Home location:", s.homeURL.path) { [weak f] text in
                // Only an existing folder: a mistyped path would break Home, new tabs and new windows.
                var isDir: ObjCBool = false
                let path = (text as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    s.homeURL = URL(fileURLWithPath: path)
                } else {
                    NSSound.beep()
                    f?.refresh()   // back to the saved location
                }
            }
            f.button("Use Current Location") {
                // The frontmost Porpoise window (this Settings window is the main window while it is open).
                let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? MainWindowController }.first
                if let u = front?.view.url, u.isFileURL { s.homeURL = u } else { NSSound.beep() }
            }
            f.button("Use Default Location") { s.homeURL = FileManager.default.homeDirectoryForCurrentUser }
            f.section("Opening folders")
            f.check("Keep a single Porpoise window, opening new folders in tabs", s.singleWindow) { s.singleWindow = $0 }
            f.section("Window")
            f.check("Show full path in window title", s.showFullPathInTitle) { s.showFullPathInTitle = $0 }
            f.check("Show Applications as an app library", s.appLibraryView) { s.appLibraryView = $0 }
            f.note("The window title appears in the Window menu, Mission Control and the Dock's window list (the toolbar takes the title bar's place).")
            f.check("Show filter bar", s.showFilterBarOnStartup) { s.showFilterBarOnStartup = $0 }
            f.section("Tabs")
            f.check("Always show tab bar", s.alwaysShowTabBar) { s.alwaysShowTabBar = $0 }
            f.check("Show close button on tabs", s.closeButtonsOnTabs) { s.closeButtonsOnTabs = $0 }
            f.popup("Tab width:", ["Adapt to folder name", "Fixed width", "Span available width"], TabStyle.allCases.firstIndex(of: s.tabStyle) ?? 0) { s.tabStyle = TabStyle.allCases[$0] }
            f.popup("Open new tabs:", ["After current tab", "At end of tab bar"], s.openNewTabsAtEnd ? 1 : 0) { s.openNewTabsAtEnd = $0 == 1 }
            f.section("Split view")
            f.popup("When closing:", ["Close the active pane", "Close the inactive pane", "Always close the right pane"],
                    CloseSplitChoice.allCases.firstIndex(of: s.closeSplitChoice) ?? 0) { s.closeSplitChoice = CloseSplitChoice.allCases[$0] }
            f.check("Open new windows in split view mode", s.splitViewOnStartup) { s.splitViewOnStartup = $0 }
        }

        page("View", "square.grid.2x2") { f in
            f.section("Display style")
            f.radio(["Use common display style for all folders", "Remember display style for each folder"], s.rememberPerFolder ? 1 : 0) { s.rememberPerFolder = $0 == 1 }
            // Only with the common style: a folder's remembered style always wins.
            f.check("Use icons view mode for locations which mostly contain media files", s.dynamicView,
                    enabled: { !s.rememberPerFolder }) { s.dynamicView = $0 }
            f.section("Browsing")
            f.check("Browse compressed files as folders", s.browseArchives) { s.browseArchives = $0 }
            f.check("Open folders during drag operations", s.openFoldersDuringDrag) { s.openFoldersDuringDrag = $0 }
            f.section("Miscellaneous")
            f.check("Show item information on hover", s.showToolTips) { s.showToolTips = $0 }
            f.check("Show selection marker", s.showSelectionMarker) { s.showSelectionMarker = $0 }
            f.check("Rename single items inline", s.renameInline) { s.renameInline = $0 }
            f.check("Also hide backup files while hiding hidden files", s.hideBackupFiles) { s.hideBackupFiles = $0 }
            f.check("Always show file extensions", s.showAllExtensions) { s.showAllExtensions = $0 }
            f.note("When off, files are shown without their extension (“report” instead of “report.pdf”). Renaming still shows the full name.")
            f.popup("Double-click on empty space:", BackgroundDoubleClick.allCases.map(\.title),
                    BackgroundDoubleClick.allCases.firstIndex(of: s.doubleClickBackground) ?? 1) { s.doubleClickBackground = BackgroundDoubleClick.allCases[$0] }
            f.section("Content display")
            f.popup("Sorting mode:", SortingChoice.allCases.map(\.title), SortingChoice.allCases.firstIndex(of: s.sortingChoice) ?? 0) { s.sortingChoice = SortingChoice.allCases[$0] }
            f.popup("Folder size:", ["Show number of items", "Show size of contents", "Show no size"],
                    FolderSizeMode.allCases.firstIndex(of: s.folderSizeMode) ?? 0) { s.folderSizeMode = FolderSizeMode.allCases[$0] }
            f.stepper("Size of contents, up to:", s.folderSizeDepth, 1...30, suffix: "levels deep",
                      enabled: { s.folderSizeMode == .contentSize }) { s.folderSizeDepth = $0 }
            f.popup("Date style:", ["Relative (e.g. 'Yesterday at 14:00')", "Absolute"], s.dateStyle == .relative ? 0 : 1) { s.dateStyle = $0 == 0 ? .relative : .absolute }
            f.popup("Permissions:", ["Symbolic (drwxr-xr-x)", "Numeric (755)", "Combined"],
                    PermissionStyle.allCases.firstIndex(of: s.permissionStyle) ?? 0) { s.permissionStyle = PermissionStyle.allCases[$0] }
            f.popup("Long file names:", ["Elide in the middle", "Elide at the end"], s.elideMiddle ? 0 : 1) { s.elideMiddle = $0 == 0 }
        }

        page("View Modes", "rectangle.grid.1x2") { f in
            f.section("Label font")
            f.fontPicker("Font:", name: s.labelFontName, size: s.labelFontSize) { name, size in s.labelFontName = name; s.labelFontSize = size }
            f.section("Icons")
            f.popup("Label width:", ["Small", "Medium", "Large", "Huge"], s.iconsLabelWidthIndex) { s.iconsLabelWidthIndex = $0 }
            f.popup("Maximum lines:", ["Unlimited", "1", "2", "3", "4", "5"], max(0, s.iconsMaxLines)) { s.iconsMaxLines = $0 }
            f.section("Compact")
            f.popup("Maximum width:", ["Unlimited", "Small", "Medium", "Large", "Huge"], [0, 10, 20, 30, 45].firstIndex(of: s.compactMaxWidth) ?? 0) { s.compactMaxWidth = [0, 10, 20, 30, 45][$0] }
            f.section("Details")
            f.check("Expandable folders", s.detailsExpandableFolders) { s.detailsExpandableFolders = $0 }
            f.check("Highlight entire row", s.detailsHighlightEntireRow) { s.detailsHighlightEntireRow = $0 }
            f.radio(["Open files and folders by clicking anywhere on the row", "Open files and folders by clicking on the icon or name"],
                    s.detailsClickAnywhere ? 0 : 1) { s.detailsClickAnywhere = $0 == 0 }
            f.section("Default icon size")
            f.note("Use the slider in the status bar, pinch, or ⌘+/⌘− to change the size of each view.")
        }

        page("Previews", "photo.on.rectangle") { f in
            f.section("Show previews for")
            f.check("Images", s.previewImages) { s.previewImages = $0 }
            f.check("Videos", s.previewVideos) { s.previewVideos = $0 }
            f.check("PDFs and documents", s.previewDocuments) { s.previewDocuments = $0 }
            f.check("Text files", s.previewText) { s.previewText = $0 }
            f.check("Fonts", s.previewFonts) { s.previewFonts = $0 }
            f.check("Folders (show their contents)", s.previewFolders) { s.previewFolders = $0 }
            f.section("Size limits")
            f.stepper("Local files below:", s.previewMaxSizeMiB, 0...10000, suffix: "MiB (0 = no limit)") { s.previewMaxSizeMiB = $0 }
            f.check("Show previews for remote files", s.previewRemote) { s.previewRemote = $0 }
        }

        page("Context Menu", "contextualmenu.and.cursorarrow") { f in
            f.section("Show in context menus")
            for e in ContextMenuEntry.allCases {
                f.check(e.title, s.contextMenuShows(e)) { s.setContextMenu(e, $0) }
            }
        }

        page("Bars & Panels", "sidebar.left") { f in
            f.section("Status bar")
            f.popup("Status bar:", ["Small", "Full width", "Disabled"], StatusBarMode.allCases.firstIndex(of: s.statusBarMode) ?? 1) { s.statusBarMode = StatusBarMode.allCases[$0] }
            // The small status bar has no room for it (Dolphin shows it in the full-width bar only).
            f.check("Show zoom slider", s.showZoomSlider, enabled: { s.statusBarMode == .fullWidth }) { s.showZoomSlider = $0 }
            f.section("Location bar")
            f.check("Make location bar editable", s.editableLocation) { s.editableLocation = $0 }
            f.check("Show full path inside location bar", s.showFullPathInLocation) { s.showFullPathInLocation = $0 }
            f.section("Information panel")
            f.check("Show preview", s.infoShowPreview) { s.infoShowPreview = $0 }
            f.check("Auto-play media files", s.infoAutoPlay, enabled: { s.infoShowPreview }) { s.infoAutoPlay = $0 }
            f.check("Show item on hover", s.infoShowHovered) { s.infoShowHovered = $0 }
            f.radio(["Long date format", "Condensed date format"], s.infoCondensedDates ? 1 : 0) { s.infoCondensedDates = $0 == 1 }
            f.section("Folders panel")
            f.check("Limit to Home folder", s.foldersLimitToHome) { s.foldersLimitToHome = $0 }
            f.check("Show hidden folders", s.foldersShowHidden) { s.foldersShowHidden = $0 }
            f.section("Terminal panel")
            f.check("Follow folder changes (both directions)", s.terminalFollowsDirectory) { s.terminalFollowsDirectory = $0 }
        }

        page("Confirmations", "checkmark.shield") { f in
            f.section("Ask for confirmation when")
            f.check("Moving files or folders to trash", s.confirmTrash) { s.confirmTrash = $0 }
            f.check("Deleting files or folders", s.confirmDelete) { s.confirmDelete = $0 }
            f.check("Emptying the trash", s.confirmEmptyTrash) { s.confirmEmptyTrash = $0 }
            f.check("Renaming changes a file's type", s.confirmRenameType) { s.confirmRenameType = $0 }
            f.check("Renaming hides an item", s.confirmRenameHide) { s.confirmRenameHide = $0 }
            f.check("Closing windows with multiple tabs", s.confirmCloseTabs) { s.confirmCloseTabs = $0 }
            f.check("Closing with a program running in the Terminal panel", s.confirmCloseTerminal) { s.confirmCloseTerminal = $0 }
            f.check("Opening many folders or files at once", s.confirmOpenMany) { s.confirmOpenMany = $0 }
            f.check("Opening many terminals at once", s.confirmManyTerminals) { s.confirmManyTerminals = $0 }
            f.popup("When opening an executable file:", ["Always ask", "Open in application", "Run script"],
                    ExecutableAction.allCases.firstIndex(of: s.executableAction) ?? 0) { s.executableAction = ExecutableAction.allCases[$0] }
            f.section("")
            f.button("Restore All Defaults") {
                let a = NSAlert()
                a.messageText = "Restore all Porpoise settings to their defaults?"
                a.informativeText = "Places, open tabs and the view styles saved for single folders are kept."
                a.addButton(withTitle: "Restore Defaults")
                a.addButton(withTitle: "Cancel")
                a.runSheet(for: SettingsWindowController.window) { r in
                    guard r == .alertFirstButtonReturn else { return }
                    Settings.shared.resetAll()   // every control re-reads its value
                }
            }
        }

        page("Trash", "trash") { f in
            f.section("Trash")
            // Sizing the Trash walks every item in it: done in the background.
            // Kept current: re-read whenever the Trash changes (emptied, items trashed from anywhere).
            let summary = f.note("Calculating…")
            let refresh = { [weak f] in
                DispatchQueue.global(qos: .utility).async {
                    let text = TrashInfo.summary()
                    DispatchQueue.main.async { summary.stringValue = text; f?.refresh() }
                }
            }
            refresh()
            TrashInfo.watcher = FolderWatcher { _ in refresh() }
            TrashInfo.watcher?.watch([MainWindowController.userTrashURL])
            f.check("Remove items from the Trash after 30 days (Finder setting)", TrashInfo.autoEmpty) { TrashInfo.autoEmpty = $0 }
            f.button("Empty Trash…", enabled: { !TrashInfo.isEmpty }) {
                FileOperationsController.shared.emptyTrash(window: SettingsWindowController.window)
            }
        }

        page("System", "lock.shield") { f in
            f.section("Updates")
            let u = Updates.shared
            f.check("Check for updates automatically (once a day)", u.automaticallyChecks, enabled: { u.isAvailable }) { u.automaticallyChecks = $0 }
            f.check("Download and install updates automatically", u.automaticallyInstalls,
                    enabled: { u.isAvailable && u.automaticallyChecks }) { u.automaticallyInstalls = $0 }
            f.button("Check Now") { u.checkForUpdates(nil) }
            f.section("Default file browser")
            f.note("Open Porpoise instead of Finder when other apps show a file (“Show in Finder”, “Reveal in Finder”, a download’s magnifying glass). macOS keeps the desktop, and opening folders from the Dock, with Finder.")
            f.status("Status:", {
                guard SystemIntegration.isDefaultBrowser else { return (false, "Finder shows files for other apps") }
                return (true, SystemIntegration.opensFolders ? "Porpoise shows files and opens folders for other apps"
                                                             : "Porpoise shows files for other apps")
            }, button: { SystemIntegration.isDefaultBrowser ? "Restore Finder" : "Make Porpoise Default" }) { refresh in
                SystemIntegration.setDefaultBrowser(!SystemIntegration.isDefaultBrowser) { err in
                    if let err { NSAlert(error: err).runSheet(for: SettingsWindowController.window) { _ in } }
                    refresh()
                }
            }
            f.section("Android phones")
            f.note("Browsing Android phones over USB uses Google's adb tool. Porpoise downloads it from Google (about 15 MB) when you ask; Google's licence doesn't allow including it.")
            f.status("Android support:", {
                AndroidTools.isInstalled ? (true, "Installed. Connect a phone with USB debugging on; it appears under Removable Devices.")
                    : (nil, "Not installed.")
            }, button: { AndroidTools.isInstalled ? "Installed" : "Install Android Support" }) { refresh in
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
            f.section("Permissions")
            f.note("macOS keeps these in System Settings › Privacy & Security. Changes take effect the next time Porpoise starts.")
            // Find out once whether App Management is in effect (silent unless macOS reports a denial).
            if PrivacyAccess.appManagementState == .unknown { SystemIntegration.checkAppManagementInBackground() }
            for perm in SystemIntegration.permissions {
                f.status(perm.title + ":", perm.status, button: {
                    // Granted: just a link. Otherwise the request button when there is one.
                    guard perm.status().0 != true, let request = perm.request else { return "Open Settings…" }
                    return request.title
                }) { refresh in
                    if perm.status().0 != true, let r = perm.request { r.run() }
                    else if let open = perm.open { open() } else { SystemIntegration.openPrivacyPane(perm.anchor) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh() }
                }
            }
        }

        let w = NSWindow(contentViewController: tabs)
        w.initialFirstResponder = nil
        w.title = "Settings"
        w.styleMask = [.titled, .closable, .resizable]
        // Wide enough for every page's toolbar item (narrower hides the last ones behind a » menu).
        w.setContentSize(NSSize(width: 760, height: 580))
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        self.builders = builders
        super.init(window: w)
        Self.window = w
        w.center()
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Trash facts and Finder's "Remove items from the Trash after 30 days" preference.
enum TrashInfo {
    static func summary() -> String {
        let t = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: t.path) else {
            return "The Trash can be shown once Porpoise has Full Disk Access (System Settings › Privacy & Security)."
        }
        let items = names.filter { $0 != ".DS_Store" }
        let size = items.reduce(Int64(0)) { $0 + FileJob.diskSize(t.appendingPathComponent($1)) }
        return items.isEmpty ? "The Trash is empty." : "\(FileFormat.itemCount(items.count)) in the Trash, \(FileFormat.size(size))."
    }

    /// Nothing in the Trash (or it can't be read without Full Disk Access).
    static var isEmpty: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: MainWindowController.userTrashURL.path)) ?? []
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    /// Watches ~/.Trash while the Settings window exists.
    static var watcher: FolderWatcher?

    static var autoEmpty: Bool {
        get { CFPreferencesCopyAppValue("FXRemoveOldTrashItems" as CFString, "com.apple.finder" as CFString) as? Bool ?? false }
        set {
            CFPreferencesSetAppValue("FXRemoveOldTrashItems" as CFString, newValue as CFBoolean, "com.apple.finder" as CFString)
            CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        }
    }
}

/// Builds a simple two-column settings form (label | control), like KDE's KCM pages.
/// Every control re-reads its setting whenever any setting changes (menus, "Do not ask again" boxes, Restore
/// Defaults…) or a window becomes key, so the window never shows stale values. Rows that depend on another
/// setting (`enabled:`) are greyed out while they can't apply.
final class FormBuilder: NSObject {
    let stack = NSStackView()
    let view: NSView
    /// Notification observers, removed with the builder.
    private var observers: [NSObjectProtocol] = []
    /// Re-read each control's value and enabled state.
    private var refreshers: [() -> Void] = []

    override init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .gravityAreas
        stack.setHuggingPriority(.required, for: .vertical)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 30, bottom: 20, right: 30)
        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        view = container
        super.init()
        for name in [Settings.changed, NSWindow.didBecomeKeyNotification, PrivacyAccess.statusChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Shows the current value (and enabled state) of every control.
    func refresh() { refreshers.forEach { $0() } }

    /// Runs `update` now and on every refresh; with `enabled`, also greys the row out while it can't apply.
    private func track(_ row: NSView, enabled: (() -> Bool)?, _ update: @escaping () -> Void) {
        let r: () -> Void = { [weak row] in
            update()
            if let enabled, let row { Self.setEnabled(row, enabled()) }
        }
        r()
        refreshers.append(r)
    }

    private static func setEnabled(_ v: NSView, _ on: Bool) {
        if let t = v as? NSTextField, !t.isEditable {
            t.textColor = on ? .labelColor : .disabledControlTextColor
        } else if let c = v as? NSControl {
            c.isEnabled = on
        }
        v.subviews.forEach { setEnabled($0, on) }
    }

    func section(_ title: String) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
        guard !title.isEmpty else { return }
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(l)
    }

    func check(_ title: String, _ value: @autoclosure @escaping () -> Bool, enabled: (() -> Bool)? = nil, _ set: @escaping (Bool) -> Void) {
        let b = ClosureButton(checkboxWithTitle: title) { set($0.state == .on) }
        let row = indented(b)
        stack.addArrangedSubview(row)
        track(row, enabled: enabled) { [weak b] in b?.state = value() ? .on : .off }
    }

    func radio(_ titles: [String], _ selected: @autoclosure @escaping () -> Int, _ set: @escaping (Int) -> Void) {
        // Radio buttons in different rows don't group automatically; keep exactly one selected.
        final class Group { var buttons: [WeakRef<NSButton>] = [] }
        let group = Group()
        for (i, t) in titles.enumerated() {
            let b = ClosureButton(radioButtonWithTitle: t) { [group] sender in
                for case let other? in group.buttons.map(\.value) where other !== sender { other.state = .off }
                sender.state = .on
                set(i)
            }
            group.buttons.append(WeakRef(b))
            stack.addArrangedSubview(indented(b))
        }
        track(stack, enabled: nil) { [group] in
            let sel = selected()
            for (i, b) in group.buttons.enumerated() { b.value?.state = i == sel ? .on : .off }
        }
    }

    func popup(_ label: String, _ items: [String], _ selected: @autoclosure @escaping () -> Int, enabled: (() -> Bool)? = nil,
               _ set: @escaping (Int) -> Void) {
        let p = ClosurePopup { set($0.indexOfSelectedItem) }
        p.addItems(withTitles: items)
        let row = labeled(label, p)
        stack.addArrangedSubview(row)
        track(row, enabled: enabled) { [weak p] in p?.selectItem(at: min(max(0, selected()), items.count - 1)) }
    }

    @discardableResult
    func text(_ label: String, _ value: @autoclosure @escaping () -> String, _ set: @escaping (String) -> Void) -> NSTextField {
        let f = ClosureTextField(string: value()) { set($0.stringValue) }
        f.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(labeled(label, f))
        // Not while the user is typing in it.
        track(f, enabled: nil) { [weak f] in if let f, f.currentEditor() == nil { f.stringValue = value() } }
        return f
    }

    func stepper(_ label: String, _ value: @autoclosure @escaping () -> Int, _ range: ClosedRange<Int>, suffix: String,
                 enabled: (() -> Bool)? = nil, _ set: @escaping (Int) -> Void) {
        let st = ClosureStepper { set($0.integerValue) }
        st.minValue = Double(range.lowerBound); st.maxValue = Double(range.upperBound)
        st.increment = range.upperBound > 1000 ? 10 : 1
        let field = ClosureTextField(string: "") { [weak st] tf in
            // Out-of-range input is clamped, and the field shows the value actually saved.
            let v = min(range.upperBound, max(range.lowerBound, tf.integerValue))
            tf.integerValue = v
            st?.integerValue = v; set(v)
        }
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        st.onChange = { [weak field] in field?.integerValue = $0 }
        let row = NSStackView(views: [field, st, NSTextField(labelWithString: suffix)])
        row.spacing = 6
        let labeledRow = labeled(label, row)
        stack.addArrangedSubview(labeledRow)
        track(labeledRow, enabled: enabled) { [weak field, weak st] in
            guard let field, let st, field.currentEditor() == nil else { return }
            st.integerValue = value(); field.integerValue = value()
        }
    }

    @discardableResult
    func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(indented(l))
        return l
    }

    func fontPicker(_ label: String, name: @autoclosure @escaping () -> String, size: @autoclosure @escaping () -> Double,
                    _ set: @escaping (String, Double) -> Void) {
        let families = ["System Font"] + NSFontManager.shared.availableFontFamilies
        let p = ClosurePopup { pop in
            let fam = pop.indexOfSelectedItem == 0 ? "" : (pop.titleOfSelectedItem ?? "")
            let psName = fam.isEmpty ? "" : (NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 13)?.fontName ?? "")
            set(psName, size())
        }
        p.addItems(withTitles: families)
        let sizes = ["10", "11", "12", "13", "14", "15", "16", "18"]
        let sp = ClosurePopup { pop in set(name(), Double(pop.titleOfSelectedItem ?? "13") ?? 13) }
        sp.addItems(withTitles: sizes)
        let row = NSStackView(views: [p, sp])
        row.spacing = 6
        stack.addArrangedSubview(labeled(label, row))
        track(row, enabled: nil) { [weak p, weak sp] in
            let n = name()
            p?.selectItem(withTitle: n.isEmpty ? "System Font" : (NSFont(name: n, size: 13)?.familyName ?? "System Font"))
            sp?.selectItem(withTitle: "\(Int(size()))")
        }
    }

    /// A status line (✓ / ✕ / ·) with a button; re-checked on every refresh (a window becoming key, a permission check ending).
    func status(_ label: String, _ state: @escaping () -> (Bool?, String), button: @escaping () -> String,
                _ action: @escaping (_ refresh: @escaping () -> Void) -> Void) {
        let icon = NSImageView()
        let text = NSTextField(wrappingLabelWithString: "")
        text.preferredMaxLayoutWidth = 300
        text.widthAnchor.constraint(equalToConstant: 300).isActive = true   // the buttons line up
        text.textColor = .secondaryLabelColor
        let b = ClosureButton(title: button()) { _ in }
        let refresh = { [weak icon, weak text, weak b] in
            let (ok, msg) = state()
            text?.stringValue = msg
            let sym = ok == true ? "checkmark.circle.fill" : (ok == false ? "xmark.circle.fill" : "info.circle")
            icon?.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            icon?.contentTintColor = ok == true ? .systemGreen : (ok == false ? .systemOrange : .secondaryLabelColor)
            b?.title = button()
        }
        b.handler = { _ in action(refresh) }
        refresh()
        refreshers.append(refresh)
        let row = NSStackView(views: [icon, text, b])
        row.spacing = 8
        row.alignment = .firstBaseline
        stack.addArrangedSubview(labeled(label, row))
    }

    func button(_ title: String, enabled: (() -> Bool)? = nil, _ action: @escaping () -> Void) {
        let b = ClosureButton(title: title) { _ in action() }
        let row = indented(b)
        stack.addArrangedSubview(row)
        if enabled != nil { track(row, enabled: enabled) {} }
    }

    private func indented(_ v: NSView) -> NSView {
        let row = NSStackView(views: [v])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        return row
    }

    /// The label column's width constraints: one width per page, wide enough for its longest label.
    private var labelWidths: [NSLayoutConstraint] = []

    private func labeled(_ label: String, _ v: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        let width = max(140, ceil(l.fittingSize.width), labelWidths.first?.constant ?? 0)
        labelWidths.append(l.widthAnchor.constraint(equalToConstant: width))
        labelWidths.forEach { $0.constant = width; $0.isActive = true }
        let row = NSStackView(views: [l, v])
        row.spacing = 8
        return row
    }
}

private final class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}

final class ClosureButton: NSButton {
    var handler: ((NSButton) -> Void)?
    /// A checkbox or radio button (it has an on/off state).
    private(set) var isToggle = false
    convenience init(checkboxWithTitle t: String, _ h: @escaping (NSButton) -> Void) {
        self.init(checkboxWithTitle: t, target: nil, action: nil)
        handler = h; target = self; action = #selector(fire); isToggle = true
    }
    convenience init(radioButtonWithTitle t: String, _ h: @escaping (NSButton) -> Void) {
        self.init(radioButtonWithTitle: t, target: nil, action: nil)
        handler = h; target = self; action = #selector(fire); isToggle = true
    }
    convenience init(title t: String, _ h: @escaping (NSButton) -> Void) {
        self.init(title: t, target: nil, action: nil)
        handler = h; target = self; action = #selector(fire)
    }
    @objc private func fire() { handler?(self) }
}

final class ClosurePopup: NSPopUpButton {
    private var handler: ((NSPopUpButton) -> Void)?
    convenience init(_ h: @escaping (NSPopUpButton) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        handler = h; target = self; action = #selector(fire)
    }
    @objc private func fire() { handler?(self) }
}

final class ClosureStepper: NSStepper {
    private var handler: ((NSStepper) -> Void)?
    var onChange: ((Int) -> Void)?
    convenience init(_ h: @escaping (NSStepper) -> Void) {
        self.init(frame: .zero)
        handler = h; target = self; action = #selector(fire)
    }
    @objc private func fire() { handler?(self); onChange?(integerValue) }
}

final class ClosureTextField: NSTextField {
    private var handler: ((NSTextField) -> Void)?
    convenience init(string: String, _ h: @escaping (NSTextField) -> Void) {
        self.init(string: string)
        handler = h; target = self; action = #selector(fire)
    }
    @objc private func fire() { handler?(self) }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        handler?(self)
    }
}
