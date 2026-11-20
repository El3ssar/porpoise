import AppKit
import CoreGraphics
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

/// Owns the desktop surfaces; construction alone never reads Desktop or creates windows.
@MainActor final class DesktopModeController: NSObject {
    static let shared = DesktopModeController()
    static let changed = Notification.Name("PorpoiseDesktopModeChanged")
    private let makeWindow: @MainActor () -> DesktopWindowController
    private let readEnvironment: @MainActor () -> DesktopEnvironment
    private let openSettings: @MainActor () -> Void
    private let observesSystemChanges: Bool
    private let preferencesDirectory: URL
    private var settingsObservation: NSObjectProtocol?
    private var environmentObservations: [(NotificationCenter, NSObjectProtocol)] = []
    private var preferenceWatcher: FolderWatcher?
    private(set) var environment = DesktopEnvironment(conflicts: [.unreadable])
    private(set) var pausedStatusItem: NSStatusItem?
    private(set) var windowController: DesktopWindowController?
    var isEnabled: Bool { windowController != nil }
    var keepsAppRunning: Bool { settingsObservation != nil && Settings.shared.desktopModeEnabled }

    init(
        environment: @escaping @MainActor () -> DesktopEnvironment = { DesktopEnvironment.current() },
        observesSystemChanges: Bool = (!Settings.isTesting || Bundle.main.bundleIdentifier == "app.porpoise.DesktopPrototype")
            && !TestEnvironment.desktopEnvironment.isSet,
        openSettings: @escaping @MainActor () -> Void = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
        },
        preferencesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true),
        makeWindow: @escaping @MainActor () -> DesktopWindowController = {
            // A test instance shows the folder it was given, never the real Desktop.
            TestEnvironment.desktopDirectory.value().map { DesktopWindowController(location: URL(fileURLWithPath: $0, isDirectory: true)) }
                ?? DesktopWindowController()
        }
    ) {
        readEnvironment = environment
        self.observesSystemChanges = observesSystemChanges
        self.openSettings = openSettings
        self.preferencesDirectory = preferencesDirectory
        self.makeWindow = makeWindow
        super.init()
    }

    deinit {
        if let settingsObservation { NotificationCenter.default.removeObserver(settingsObservation) }
        environmentObservations.forEach { $0.0.removeObserver($0.1) }
        if let pausedStatusItem { NSStatusBar.system.removeStatusItem(pausedStatusItem) }
    }

    func start() {
        if settingsObservation == nil {
            settingsObservation = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] n in
                let keys = ["desktopModeEnabled", "desktopShowMenuBarIcon", "desktopMonochromeMenuBarIcon"]
                guard n.object == nil || (n.object as? String).map(keys.contains) == true else { return }
                MainActor.assumeIsolated { self?.checkEnvironment() }
            }
        }
        checkEnvironment()
    }

    /// Quitting tears down this session without changing the user's choice for the next launch.
    func stop() {
        if let settingsObservation { NotificationCenter.default.removeObserver(settingsObservation) }
        settingsObservation = nil
        stopEnvironmentObservation()
        applyEnabled(false)
        removePausedStatusItem()
    }

    func setEnabled(_ enabled: Bool) {
        if Settings.shared.desktopModeEnabled != enabled { Settings.shared.desktopModeEnabled = enabled }
        start()
    }

    var statusLine: (Bool?, String) {
        if !Settings.shared.desktopModeEnabled { return (nil, "macOS desktop selected. Porpoise is off.") }
        if isEnabled { return (true, "Porpoise desktop active. macOS desktop items are hidden.") }
        return (false, "Porpoise desktop paused.\n" + environment.conflicts.map(\.instruction).joined(separator: "\n"))
    }

    /// Recheck before creating any listing/surface, after returning from System Settings, and on preference events.
    @objc func checkEnvironment() {
        guard settingsObservation != nil else { return }
        if !Settings.shared.desktopModeEnabled {
            stopEnvironmentObservation()
            applyEnabled(false)
            removePausedStatusItem()
            return
        }
        observeEnvironment()
        let previous = environment
        environment = readEnvironment()
        // Close the old surfaces before exposing a setup menu. An external change never enables a hybrid mode.
        applyEnabled(environment.isReady)
        updatePausedStatusItem()
        if previous != environment { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    @objc func openDesktopSettings() { openSettings() }

    @objc private func showSetup() { AppDelegate.shared.showSettings(page: "Advanced", section: "Experiments") }
    @objc private func useMacOSDesktop() { setEnabled(false) }

    private func observeEnvironment() {
        guard observesSystemChanges, preferenceWatcher == nil else { return }
        let watcher = FolderWatcher(reportEventPaths: true) { [weak self] paths in
            guard paths.contains(where: DesktopEnvironment.isPreferenceChange) else { return }
            DispatchQueue.main.async { self?.checkEnvironment() }
        }
        watcher.watch([preferencesDirectory, preferencesDirectory.appendingPathComponent("ByHost", isDirectory: true)])
        preferenceWatcher = watcher
        for (center, names) in [
            (NotificationCenter.default, [NSApplication.didBecomeActiveNotification]),
            (NSWorkspace.shared.notificationCenter, [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification]),
        ] {
            for name in names {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkEnvironment() }
                }
                environmentObservations.append((center, token))
            }
        }
    }

    private func stopEnvironmentObservation() {
        preferenceWatcher?.stop()
        preferenceWatcher = nil
        environmentObservations.forEach { $0.0.removeObserver($0.1) }
        environmentObservations = []
    }

    private func removePausedStatusItem() {
        if let pausedStatusItem { NSStatusBar.system.removeStatusItem(pausedStatusItem) }
        pausedStatusItem = nil
    }

    /// A login launch can need setup without having any browser windows. Keep its recovery controls accessible.
    private func updatePausedStatusItem() {
        guard !environment.isReady, Settings.shared.desktopShowMenuBarIcon else { removePausedStatusItem(); return }
        let item = pausedStatusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = DesktopWindowController.menuBarIcon(monochrome: Settings.shared.desktopMonochromeMenuBarIcon)
        item.button?.toolTip = statusLine.1
        item.button?.setAccessibilityLabel("Porpoise Desktop Mode — Setup Required")
        let menu = NSMenu()
        menu.addItem(withTitle: "Desktop Mode paused — setup required", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for entry in [
            NSMenuItem.make("Desktop Mode Settings…", #selector(showSetup), icon: "configure"),
            .make("Open macOS Desktop Settings…", #selector(openDesktopSettings), icon: "configure"),
            .make("Check Again", #selector(checkEnvironment), icon: "view-refresh"),
            .make("Use macOS Desktop", #selector(useMacOSDesktop), icon: "tab-close"),
        ] {
            entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem.make("Quit Porpoise", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp; menu.addItem(quit)
        item.menu = menu
        pausedStatusItem = item
    }

    private func applyEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            let controller = makeWindow()
            windowController = controller
            controller.onDisable = { [weak self] in self?.setEnabled(false) }
            controller.start()
        } else {
            let controller = windowController
            windowController = nil
            controller?.onDisable = nil
            controller?.close()
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

/// All desktop surfaces share this listing; there is no separate preview or control window.
final class DesktopWindowController: NSResponder, ItemListViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    private(set) var model: DirectoryModel?
    private(set) var statusText = "Loading…"
    private let statusEntry = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    private(set) var gridPreferences: DesktopGridPreferences
    private let preferenceStore: UserDefaults
    private let layoutScope: String
    private(set) var desktopPlacementEnabled = false
    private(set) var desktopWindows: [CGDirectDisplayID: DesktopSurfaceWindowController] = [:]
    private let displays: @MainActor () -> [DesktopDisplay]
    private let screenNotifications: NotificationCenter
    private var screenObservation: NSObjectProtocol?
    private var cutObservation: NSObjectProtocol?
    private var settingsObservation: NSObjectProtocol?
    private(set) var statusItem: NSStatusItem?
    var onDisable: (() -> Void)?
    weak var activeGrid: DesktopGridView?
    var spacePreview: SpacePreviewPanel?
    var localFileOpening = LocalFileOpening()
    var itemRenaming = ItemRenaming()
    private var changingView = false

    var grids: [DesktopGridView] { desktopWindows.values.compactMap(\.collectionView) }

    init(
        location: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0],
        screenNotifications: NotificationCenter = .default,
        displays: @escaping @MainActor () -> [DesktopDisplay] = { DesktopDisplay.current() }
    ) {
        self.displays = displays
        self.screenNotifications = screenNotifications
        preferenceStore = Settings.store
        layoutScope = location.absoluteString
        gridPreferences = DesktopGridPreferences.load(from: Settings.store)
        let model = DirectoryModel(location: location, prefetchFolders: false)
        var props = gridPreferences.viewProperties ?? model.props
        props.mode = .icons
        props.groupRole = nil
        props.groupSameAsSort = false
        model.props = props
        self.model = model
        super.init()

        model.onChange = { [weak self] in self?.updateListing() }
        model.onLoaded = { [weak self] in self?.updateListing() }
        model.onMetadataLoaded = { [weak self] in self?.grids.forEach { $0.needsDisplay = true } }
        model.onSelectionChanged = { [weak self] in
            self?.grids.forEach {
                $0.needsDisplay = true; $0.accessibilitySelectionChanged()
            }
        }
        model.onPropsChanged = { [weak self] in
            guard let self, let model = self.model else { return }
            self.gridPreferences.viewProperties = model.props
            self.gridPreferences.save(to: self.preferenceStore)
        }
        cutObservation = NotificationCenter.default.addObserver(forName: FileOperationsController.cutChanged, object: nil, queue: .main) {
            [weak self] _ in
            self?.grids.forEach {
                $0.cutURLs = FileOperationsController.shared.cutURLs; $0.needsDisplay = true
            }
        }
        settingsObservation = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] n in
            let keys = ["desktopShowMenuBarIcon", "desktopMonochromeMenuBarIcon"]
            if n.object == nil || (n.object as? String).map(keys.contains) == true { self?.updateStatusItem() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let screenObservation { screenNotifications.removeObserver(screenObservation) }
        if let cutObservation { NotificationCenter.default.removeObserver(cutObservation) }
        if let settingsObservation { NotificationCenter.default.removeObserver(settingsObservation) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func configureGrid(_ view: DesktopGridView, scope: String) {
        view.scope = scope
        view.delegate = self
        view.onRearrange = { [weak self] positions in
            guard let self, self.model != nil else { return }
            self.gridPreferences.positions[scope] = positions
            self.gridPreferences.save(to: self.preferenceStore)
            self.updateListing()
        }
    }

    func setGridCorner(_ corner: DesktopGridCorner) {
        guard model != nil else { return }
        gridPreferences.corner = corner
        gridPreferences.save(to: preferenceStore)
        updateListing()
    }

    @objc func menuCorner(_ sender: NSMenuItem) { setGridCorner(DesktopGridCorner.allCases[sender.tag]) }
    @objc func showInPorpoise(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { AppDelegate.shared.reveal([url]) }
    }
    @objc func showPorpoise() {
        AppDelegate.shared.openDesktopFolders(
            [model?.location ?? Settings.shared.homeURL], inTabs: Settings.shared.desktopFoldersInTabs,
            maximized: Settings.shared.desktopOpenMaximized, screen: activeGrid?.window?.screen)
    }

    func start() { setDesktopPlacementEnabled(true) }

    func setDesktopPlacementEnabled(_ enabled: Bool) {
        guard model != nil, enabled != desktopPlacementEnabled else { return }
        desktopPlacementEnabled = enabled
        if enabled {
            updateStatusItem()
            screenObservation = screenNotifications.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileDesktopWindows() }
            }
            reconcileDesktopWindows()
        } else {
            removeStatusItem()
            if let screenObservation { screenNotifications.removeObserver(screenObservation) }
            screenObservation = nil
            let closing = desktopWindows.values
            desktopWindows.removeAll()
            for controller in closing { controller.close() }
            updateListing()
        }
    }

    private func removeStatusItem() {
        if let statusItem {
            statusItem.menu?.removeItem(statusEntry)
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func updateStatusItem() {
        guard desktopPlacementEnabled, Settings.shared.desktopShowMenuBarIcon else { removeStatusItem(); return }
        let image = Self.menuBarIcon(monochrome: Settings.shared.desktopMonochromeMenuBarIcon)
        if let statusItem { statusItem.button?.image = image; return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = image
        item.button?.toolTip = "Porpoise Desktop Mode"
        item.button?.setAccessibilityLabel("Porpoise Desktop Mode")
        let menu = NSMenu()
        menu.delegate = self
        fillStatusMenu(menu)
        item.menu = menu
        statusItem = item
    }

    /// Keep the native background commands available in the optional menu-bar menu as well.
    private func fillStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(statusEntry)
        menu.addItem(.separator())
        let show = NSMenuItem.make("Show in Porpoise", #selector(showPorpoise), icon: "document-open-folder")
        show.target = self; menu.addItem(show)
        menu.addItem(.separator())
        let background = desktopMenu(for: nil)
        for entry in background.items {
            background.removeItem(entry); menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem.make("Quit Porpoise", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp; menu.addItem(quit)
        MenuCommandRegistry.shared.apply(to: menu)
    }

    /// As when the background menu opened: the Paste title, the sort marks and the start corner are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem?.menu { fillStatusMenu(menu) }
    }

    /// The existing app mark, as a black/clear template so the menu bar supplies its native contrast.
    static func menuBarIcon(monochrome: Bool) -> NSImage? {
        let image: NSImage?
        if monochrome {
            let svg = """
                <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="180 300 664 460">
                <path d="M 203.00 595.75 A 434.98 434.98 0 0 1 330.34 506.67 A 145.89 145.89 0 0 0 376.65 473.03 A 236.05 236.05 0 0 0 434.56 359.50 A 34.44 34.44 0 0 1 480.52 334.08 A 381.95 381.95 0 0 1 655.61 468.60 A 145.89 145.89 0 0 0 708.30 513.73 A 434.98 434.98 0 0 1 821.00 595.75 A 381.95 381.95 0 0 1 748.05 585.34 A 999.95 999.95 0 0 0 275.95 585.34 A 381.95 381.95 0 0 1 203.00 595.75 Z" fill="black"/><path d="M 203.00 651.53 A 437.67 437.67 0 0 0 289.10 639.49 A 944.22 944.22 0 0 1 734.90 639.49 A 437.67 437.67 0 0 0 821.00 651.53" fill="none" stroke="black" stroke-width="34.4" stroke-linecap="round"/><path d="M 321.03 724.60 A 854.05 854.05 0 0 1 702.97 724.60" fill="none" stroke="black" stroke-width="21.3" stroke-linecap="round"/>
                </svg>
                """
            image = NSImage(data: Data(svg.utf8))
        } else {
            image = NSApp.applicationIconImage.copy() as? NSImage
        }
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = monochrome
        return image
    }

    private func reconcileDesktopWindows() {
        guard desktopPlacementEnabled, model != nil else { return }
        let level = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        guard level < Int(CGWindowLevelForKey(.normalWindow)) else {
            setDesktopPlacementEnabled(false)
            statusText = "Desktop placement isn’t available on this system."
            StatusCenter.post(statusText)
            return
        }
        // Stable display IDs survive geometry and scale changes. Never retain NSScreen instances across notifications.
        let current = Dictionary(displays().filter { !$0.frame.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in desktopWindows.keys.filter({ current[$0] == nil }) { desktopWindows.removeValue(forKey: id)?.close() }
        for display in current.values {
            if let controller = desktopWindows[display.id] {
                controller.window?.setFrame(display.frame, display: true)
            } else {
                let controller = DesktopSurfaceWindowController(display: display, level: level, model: model!, delegate: self)
                controller.window?.nextResponder = self
                configureGrid(controller.collectionView, scope: layoutScope + "|display:\(display.id)")
                desktopWindows[display.id] = controller
                controller.window?.orderFrontRegardless()
            }
        }
        updateListing()
    }

    @objc func reload() {
        model?.reload()
        updateListing()
    }

    @objc func disableMode() {
        if let onDisable { onDisable() } else { Settings.shared.desktopModeEnabled = false; close() }
    }

    private func updateListing() {
        guard let model else { return }
        for view in grids {
            let apply = {
                view.corner = self.gridPreferences.corner
                let saved = self.gridPreferences.positions[view.scope] ?? [:]
                view.preferred = Dictionary(
                    uniqueKeysWithValues: view.itemKeys.enumerated().compactMap { index, key in
                        saved[key].map { (index, $0) }
                    })
                view.relayout()
            }
            if changingView { apply() } else { view.transitions.change(.reflow, pictures: false, apply) }
            view.transitions.itemsDelivered(loading: model.isLoading)
        }
        if let error = model.loadError {
            statusText =
                model.blockedByPrivacy
                ? "macOS blocked access to Desktop. Check Privacy & Security → Files and Folders for this test app, then Refresh."
                : "Couldn’t read Desktop: \(error)"
        } else if model.isLoading {
            statusText = "Loading…"
        } else {
            statusText = model.rows.isEmpty ? "Desktop is empty." : "\(model.rows.count) items"
        }
        if desktopPlacementEnabled { statusText += " · \(desktopWindows.count) displays" }
        statusEntry.title = statusText
        statusItem?.button?.toolTip = statusText
    }

    func close() {
        setDesktopPlacementEnabled(false)
        if let cutObservation { NotificationCenter.default.removeObserver(cutObservation) }
        cutObservation = nil
        if let settingsObservation { NotificationCenter.default.removeObserver(settingsObservation) }
        settingsObservation = nil
        // Releasing the model cancels its loads and stops its FSEvents watcher, including during an in-flight load.
        model?.onChange = nil
        model?.onLoaded = nil
        model?.onSelectionChanged = nil
        model?.onPropsChanged = nil
        model?.onMetadataLoaded = nil
        model = nil
        spacePreview?.close()
        spacePreview = nil
    }

    func renamedPosition(from old: URL, to new: URL) {
        for scope in gridPreferences.positions.keys {
            if let slot = gridPreferences.positions[scope]?.removeValue(forKey: old.absoluteString) {
                gridPreferences.positions[scope]?[new.absoluteString] = slot
            }
        }
        gridPreferences.save(to: preferenceStore)
    }

    func arrangeGrid(_ update: (inout ViewProperties) -> Void) {
        guard let model else { return }
        changeView {
            for grid in grids { gridPreferences.positions.removeValue(forKey: grid.scope) }
            var props = model.props
            update(&props)
            gridPreferences.viewProperties = props
            gridPreferences.save(to: preferenceStore)
            if props == model.props { updateListing() } else { model.props = props }
        }
    }

    func changeView(_ change: () -> Void) {
        let views = grids
        func animate(_ index: Int) {
            if index < views.count {
                views[index].transitions.change(.reflow, pictures: false) { animate(index + 1) }
            } else {
                changingView = true; change(); changingView = false
            }
        }
        animate(0)
    }
}

struct DesktopDisplay {
    let id: CGDirectDisplayID
    let frame: NSRect

    @MainActor static func current() -> [DesktopDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DesktopDisplay(id: number.uint32Value, frame: screen.visibleFrame)
        }
    }
}

/// An interactive desktop grid above Finder's desktop layer and below ordinary application windows.
final class DesktopSurfaceWindowController: NSWindowController {
    private(set) var collectionView: DesktopGridView!

    init(display: DesktopDisplay, level: Int, model: DirectoryModel, delegate: ItemListViewDelegate) {
        collectionView = DesktopGridView(model: model)
        collectionView.onDesktop = true
        collectionView.delegate = delegate
        let window = DesktopSurfaceWindow(
            contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Desktop Mode — Display \(display.id)"
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: level)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.acceptsMouseMovedEvents = true
        // Hiding the browser app must leave its desktop surfaces in place.
        window.canHide = false
        window.isOpaque = false
        // The preflight requires macOS's desktop items to be hidden. Porpoise owns empty-space clicks too:
        // retain the native background menu and rubber-band selection without an opaque wallpaper overlay.
        window.backgroundColor = NSColor.black.withAlphaComponent(1.0 / 255)
        window.hasShadow = false
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        super.init(window: window)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = collectionView
        window.contentView = scroll
    }

    required init?(coder: NSCoder) { fatalError() }

    override func close() {
        collectionView?.stopPresentation()
        collectionView?.delegate = nil
        window?.contentView = nil
        collectionView = nil
        super.close()
    }
}

private final class DesktopSurfaceWindow: NSPanel {
    override func performClose(_ sender: Any?) {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
