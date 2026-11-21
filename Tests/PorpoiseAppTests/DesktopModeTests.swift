import AppKit
import CoreGraphics
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct DesktopModeTests {
    init() { _ = NSApplication.shared }

    private final class MenuProbe: ItemListViewDelegate {
        var targets: [URL?] = []
        var opened: [URL] = []
        func itemList(_ view: ItemListView, open items: [FileItem], inNewTab: Bool) { opened += items.map(\.url) }
        func itemList(_ view: ItemListView, menuFor item: FileItem?) -> NSMenu? { targets.append(item?.url); return nil }
        func itemList(_ view: ItemListView, drop urls: [URL], onto folder: URL, operation: NSDragOperation, event: NSEvent?) {}
        func itemList(_ view: ItemListView, rename item: FileItem, to name: String) {}
        func itemListDidBecomeActive(_ view: ItemListView) {}
        func itemList(_ view: ItemListView, hovered item: FileItem?) {}
        func itemListBackgroundDoubleClicked(_ view: ItemListView) {}
        func itemList(_ view: ItemListView, middleClicked item: FileItem) {}
        func itemListQuickLook(_ view: ItemListView) {}
    }

    private func makeDesktop(
        location: URL, screenNotifications: NotificationCenter = .default,
        displays: @escaping @MainActor () -> [DesktopDisplay] = { [DesktopDisplay(id: 11, frame: NSRect(x: 0, y: 0, width: 640, height: 480))] }
    ) -> DesktopWindowController {
        let controller = DesktopWindowController(location: location, screenNotifications: screenNotifications, displays: displays)
        controller.start()
        return controller
    }

    @Test func conflictsPreventListingAndSurfacesUntilSetupPasses() throws {
        let scratch = try Scratch()
        var snapshot = DesktopEnvironment(conflicts: [.finderItems, .stageManager]), creations = 0, settingsOpened = 0
        let mode = DesktopModeController(
            environment: { snapshot }, openSettings: { settingsOpened += 1 },
            makeWindow: {
                creations += 1
                return makeDesktop(location: scratch.url)
            })
        defer { mode.stop() }
        mode.start()
        #expect(creations == 0 && mode.pausedStatusItem == nil)
        mode.setEnabled(true)
        #expect(Settings.shared.desktopModeEnabled && !mode.isEnabled && mode.windowController == nil && creations == 0)
        #expect(mode.pausedStatusItem != nil && mode.statusLine.0 == false)
        #expect(mode.statusLine.1.contains("On Desktop") && mode.statusLine.1.contains("Turn off Stage Manager"))
        let form = FormBuilder(); SettingsPages.desktopMode(form, controller: mode)
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let open = try #require(views(form.view).compactMap { $0 as? NSButton }.first { $0.title == "Open macOS Desktop Settings…" })
        open.performClick(nil)
        #expect(settingsOpened == 1 && creations == 0)
        snapshot = .ready
        let check = try #require(views(form.view).compactMap { $0 as? NSButton }.first { $0.title == "Check Again" })
        check.performClick(nil)
        #expect(mode.isEnabled && creations == 1 && mode.pausedStatusItem == nil && mode.statusLine.0 == true)
        #expect(mode.windowController?.desktopWindows.count == 1)
        mode.setEnabled(false)
        #expect(!mode.isEnabled && mode.pausedStatusItem == nil && mode.statusLine.1.contains("macOS desktop selected"))
    }

    @Test func aSystemConflictClosesEverySurfaceAndPreservesTheRequestedMode() throws {
        let scratch = try Scratch()
        var snapshot = DesktopEnvironment.ready, creations = 0
        let mode = DesktopModeController(
            environment: { snapshot },
            makeWindow: {
                creations += 1
                return makeDesktop(location: scratch.url)
            })
        mode.start(); mode.setEnabled(true)
        defer { mode.stop() }
        let controller = try #require(mode.windowController)
        let windows = controller.desktopWindows.values.compactMap(\.window)
        snapshot = DesktopEnvironment(conflicts: [.finderStageItems])
        mode.checkEnvironment()
        #expect(!mode.isEnabled && Settings.shared.desktopModeEnabled && mode.pausedStatusItem != nil)
        #expect(controller.model == nil && windows.allSatisfy { !$0.isVisible })
        mode.checkEnvironment()
        #expect(creations == 1)
        mode.stop()
        snapshot = .ready
        mode.checkEnvironment()
        #expect(!mode.isEnabled && mode.pausedStatusItem == nil && creations == 1)
        mode.start()
        #expect(mode.isEnabled && creations == 2)
    }

    @Test func aBlockedLoginSessionCanDisableTheModeWithoutAnySurfaces() throws {
        let scratch = try Scratch()
        var creations = 0
        let mode = DesktopModeController(
            environment: { DesktopEnvironment(conflicts: [.stageManager]) },
            makeWindow: {
                creations += 1
                return makeDesktop(location: scratch.url)
            })
        mode.start(); mode.setEnabled(true)
        defer { mode.stop() }
        #expect(creations == 0)
        let delegate = AppDelegate(desktopMode: mode)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        Settings.shared.desktopMonochromeMenuBarIcon = true
        #expect(mode.pausedStatusItem?.button?.image?.isTemplate == true)
        // A paused login launch has no windows: the setup item is the only way back, whatever the icon preference.
        Settings.shared.desktopShowMenuBarIcon = false
        #expect(mode.pausedStatusItem?.menu != nil && Settings.shared.desktopModeEnabled)
        let menu = try #require(mode.pausedStatusItem?.menu)
        let index = try #require(menu.items.firstIndex { $0.title == "Use macOS Desktop" })
        menu.performActionForItem(at: index)
        #expect(!Settings.shared.desktopModeEnabled && mode.pausedStatusItem == nil && creations == 0)
    }

    @Test func preferenceFileEventsPauseTheDesktopWithoutPolling() async throws {
        let scratch = try Scratch()
        let preferences = try scratch.folder("Preferences")
        try FileManager.default.createDirectory(at: preferences.appendingPathComponent("ByHost"), withIntermediateDirectories: true)
        var snapshot = DesktopEnvironment.ready, reads = 0
        let mode = DesktopModeController(
            environment: {
                reads += 1; return snapshot
            }, observesSystemChanges: true, preferencesDirectory: preferences,
            makeWindow: {
                makeDesktop(location: scratch.url)
            })
        mode.start(); mode.setEnabled(true)
        defer { mode.stop() }
        #expect(mode.isEnabled)
        snapshot = DesktopEnvironment(conflicts: [.finderItems])
        let changed = preferences.appendingPathComponent("com.apple.WindowManager.plist")
        try Data("test preference event".utf8).write(to: changed, options: .atomic)
        #expect(await eventually(5) { !mode.isEnabled && mode.pausedStatusItem != nil })
        #expect(Settings.shared.desktopModeEnabled)
        mode.stop()
        let stoppedReads = reads
        snapshot = .ready
        try Data("another test preference event".utf8).write(to: changed, options: .atomic)
        mode.checkEnvironment()
        #expect(!mode.isEnabled && reads == stoppedReads)
    }

    @Test func optInDefaultAndQuitPreferenceSurviveNewSessions() throws {
        let scratch = try Scratch()
        var creations = 0
        let mode = DesktopModeController(
            environment: { .ready },
            makeWindow: {
                creations += 1; return makeDesktop(location: scratch.url)
            })
        defer { mode.stop() }
        #expect(!mode.isEnabled && creations == 0 && !Settings.shared.desktopModeEnabled)
        #expect(Settings.shared.desktopShowMenuBarIcon && !Settings.shared.desktopMonochromeMenuBarIcon)
        #expect(!Settings.shared.desktopFoldersInTabs && !Settings.shared.desktopOpenMaximized)
        // Launching alone creates nothing: the desktop exists only after the user opts in.
        mode.start()
        #expect(!mode.isEnabled && creations == 0 && mode.windowController == nil)
        mode.setEnabled(true)
        let controller = try #require(mode.windowController)
        #expect(mode.isEnabled && Settings.shared.desktopModeEnabled && controller.desktopWindows.count == 1)
        #expect(controller.desktopWindows.values.allSatisfy { $0.window?.styleMask == [.borderless, .nonactivatingPanel] })
        mode.start(); mode.setEnabled(true)
        #expect(creations == 1 && mode.windowController === controller)
        mode.stop()
        #expect(Settings.shared.desktopModeEnabled && controller.model == nil && controller.desktopWindows.isEmpty)
        mode.start()
        #expect(mode.isEnabled && creations == 2)
        mode.setEnabled(false)
        #expect(!Settings.shared.desktopModeEnabled && !mode.isEnabled)
        mode.stop()
        let next = DesktopModeController(environment: { .ready }, makeWindow: { makeDesktop(location: scratch.url) })
        defer { next.stop() }
        next.start()
        #expect(!next.isEnabled)
        next.setEnabled(true)
        #expect(next.isEnabled && Settings.shared.desktopModeEnabled)
        // Restore All Defaults turns the experiment off again, at once.
        Settings.shared.resetAll()
        #expect(!next.isEnabled && !Settings.shared.desktopModeEnabled)
    }

    @Test func disablingFromTheMenuClosesSurfacesAndReleasesTheListing() async throws {
        let scratch = try Scratch()
        let mode = DesktopModeController(environment: { .ready }, makeWindow: { makeDesktop(location: scratch.url) })
        mode.start(); mode.setEnabled(true)
        defer { mode.stop() }
        let controller = try #require(mode.windowController)
        try #require(await eventually { controller.model?.isLoading == false })
        weak var model = controller.model
        let windows = controller.desktopWindows.values.compactMap(\.window)
        let browser = MainWindowController(urls: [scratch.url])
        defer { browser.close() }
        let props = browser.view.model.props
        let menu = try #require(controller.statusItem?.menu)
        #expect(!menu.items.contains { $0.title.contains("Controls") })
        let disable = try #require(menu.items.firstIndex { $0.title == "Disable Desktop Mode" })
        menu.performActionForItem(at: disable)
        #expect(!mode.isEnabled && !Settings.shared.desktopModeEnabled)
        #expect(controller.model == nil && controller.desktopWindows.isEmpty && controller.statusItem == nil)
        #expect(windows.allSatisfy { !$0.isVisible })
        #expect(await eventually { model == nil })
        #expect(browser.view.url == scratch.url && browser.view.model.props == props)
    }

    @Test func listingUsesTheExistingWatcherAndNativeView() async throws {
        let scratch = try Scratch()
        _ = try scratch.file("original.txt", "unchanged"); _ = try scratch.folder("Folder")
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        let model = try #require(controller.model)
        try #require(await eventually { model.rows.count == 2 })
        let grid = try #require(controller.grids.first)
        #expect(grid.delegate === controller && grid.frames.count == 2 && grid.registeredDraggedTypes.isEmpty)
        #expect(grid.font == Settings.shared.labelFont && grid.maxLabelLines == Settings.shared.iconsMaxLines)
        _ = try scratch.file("external.txt")
        try #require(await eventually { model.rows.count == 3 && grid.frames.count == 3 })
        try FileManager.default.removeItem(at: scratch.path("external.txt"))
        #expect(await eventually { model.rows.count == 2 })
        #expect(scratch.read("original.txt") == "unchanged")
    }

    @Test func emptyAndMissingLocationsReportInTheStatusMenu() async throws {
        let scratch = try Scratch()
        let empty = makeDesktop(location: scratch.url)
        defer { empty.close() }
        try #require(await eventually { empty.model?.isLoading == false })
        #expect(empty.statusText.hasPrefix("Desktop is empty."))
        #expect(empty.statusItem?.menu?.items.first?.title == empty.statusText)
        let missing = makeDesktop(location: scratch.path("Missing"))
        defer { missing.close() }
        try #require(await eventually { missing.model?.loadError != nil })
        #expect(missing.statusText.hasPrefix("Couldn’t read Desktop:"))
        #expect(missing.grids.first?.frames.isEmpty == true)
        #expect(missing.statusItem?.menu?.items.contains { $0.title == "Refresh" } == true)
        // The background commands are also in the menu-bar menu, for when no empty desktop is in reach.
        let titles = empty.statusItem?.menu?.items.map(\.title) ?? []
        for title in ["New Folder…", "Add Application Shortcut…", "Sort By", "Start Corner", "Disable Desktop Mode", "Quit Porpoise"] {
            #expect(titles.contains(title), "\(title) is missing from \(titles)")
        }
        let menu = try #require(empty.statusItem?.menu)
        empty.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == empty.statusText && menu.items.map(\.title) == titles)
    }

    @Test func enableSettingStartsOffAndDoesNotChangeBrowserSettings() throws {
        let scratch = try Scratch()
        let mode = DesktopModeController(environment: { .ready }, makeWindow: { makeDesktop(location: scratch.url) })
        mode.start()
        defer { mode.stop() }
        let form = FormBuilder()
        SettingsPages.desktopMode(form, controller: mode)
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let checkbox = try #require(views(form.view).compactMap { $0 as? NSButton }.first { $0.title == "Enable Desktop Mode" })
        #expect(checkbox.state == .off && !mode.isEnabled)
        let browser = MainWindowController(urls: [scratch.url])
        defer { browser.close() }
        let props = browser.view.model.props
        checkbox.performClick(nil)
        #expect(checkbox.state == .on && mode.isEnabled && Settings.shared.desktopModeEnabled)
        checkbox.performClick(nil)
        #expect(checkbox.state == .off && !mode.isEnabled && !Settings.shared.desktopModeEnabled)
        #expect(browser.view.model.props == props && browser.view.url == scratch.url)
    }

    @Test func surfacesShareOneListingAndDoNotActivateTheAppOnStart() async throws {
        let scratch = try Scratch(); _ = try scratch.file("original.txt", "unchanged")
        let key = NSApp.keyWindow
        let controller = makeDesktop(location: scratch.url) {
            [
                DesktopDisplay(id: 11, frame: NSRect(x: 0, y: 0, width: 640, height: 480)),
                DesktopDisplay(id: 22, frame: NSRect(x: 640, y: 0, width: 800, height: 600)),
            ]
        }
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 1 })
        #expect(controller.desktopWindows.count == 2 && NSApp.keyWindow === key)
        for surface in controller.desktopWindows.values {
            let window = try #require(surface.window)
            #expect(window.isVisible && window.styleMask == [.borderless, .nonactivatingPanel] && window.canBecomeKey && !window.canBecomeMain)
            let panel = try #require(window as? NSPanel)
            #expect(!panel.isFloatingPanel && !panel.hidesOnDeactivate && surface.collectionView.needsPanelToBecomeKey)
            #expect(!window.ignoresMouseEvents && !window.isOpaque && !window.isRestorable && !window.canHide)
            #expect(window.level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)) && window.level.rawValue < 0)
            #expect(window.collectionBehavior.contains([.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]))
            #expect(surface.collectionView.model === controller.model && surface.collectionView.frames.count == 1)
        }
        _ = try scratch.file("external.txt")
        #expect(await eventually { controller.grids.allSatisfy { $0.frames.count == 2 } })
    }

    @Test func hidingTheAppAndClosingBrowserWindowsKeepTheDesktopRunning() async throws {
        let scratch = try Scratch()
        let mode = DesktopModeController(environment: { .ready }, makeWindow: { makeDesktop(location: scratch.url) }); mode.start();
        mode.setEnabled(true)
        let wasHidden = NSApp.isHidden
        defer { mode.stop(); if !wasHidden { NSApp.unhideWithoutActivation() } }
        let controller = try #require(mode.windowController)
        let surface = try #require(controller.desktopWindows[11]?.window)
        let browser = MainWindowController(urls: [scratch.url]); browser.showWindow(nil)
        browser.window?.animationBehavior = .none; browser.window?.miniaturize(nil)
        #expect(await eventually { browser.window?.isMiniaturized == true })
        #expect(surface.isVisible)
        NSApp.hide(nil)
        #expect(surface.isVisible && mode.isEnabled)
        browser.close()
        let delegate = AppDelegate(desktopMode: mode)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        // Quit is never refused on the desktop's account, whoever asks; the choice stays for the next launch.
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(Settings.shared.desktopModeEnabled)
    }

    @Test func displayChangesReconcileWindowsAndStopBeingObservedAfterDisable() async throws {
        let scratch = try Scratch()
        var displays = [
            DesktopDisplay(id: 11, frame: NSRect(x: -640, y: 0, width: 640, height: 480)),
            DesktopDisplay(id: 22, frame: NSRect(x: 0, y: 0, width: 800, height: 600)),
        ]
        var reads = 0
        let notifications = NotificationCenter()
        let controller = makeDesktop(location: scratch.url, screenNotifications: notifications) {
            reads += 1; return displays
        }
        defer { controller.close() }
        controller.setDesktopPlacementEnabled(true)
        let removed = try #require(controller.desktopWindows[11]?.window)
        let retained = try #require(controller.desktopWindows[22])
        let changedFrame = NSRect(x: 0, y: -400, width: 800, height: 400)
        displays = [
            DesktopDisplay(id: 22, frame: changedFrame),
            DesktopDisplay(id: 33, frame: NSRect(x: 800, y: 0, width: 640, height: 480)),
            DesktopDisplay(id: 44, frame: .zero),
        ]
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(Set(controller.desktopWindows.keys) == [22, 33])
        #expect(!removed.isVisible && controller.desktopWindows[22] === retained && retained.window?.frame == changedFrame)
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(controller.desktopWindows.count == 2 && controller.desktopWindows[22] === retained)
        displays = []
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(controller.desktopPlacementEnabled && controller.desktopWindows.isEmpty && retained.window?.isVisible == false)
        displays = [DesktopDisplay(id: 22, frame: changedFrame)]
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(controller.desktopWindows.count == 1 && controller.desktopWindows[22] !== retained)
        controller.setDesktopPlacementEnabled(false)
        let readsBefore = reads
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await Task.yield()
        #expect(reads == readsBefore && controller.desktopWindows.isEmpty)
    }

    @Test func allFourCornersSnapToDistinctCellsAndResizeRepairsCollisions() {
        for corner in DesktopGridCorner.allCases {
            let geometry = DesktopGridGeometry(
                viewport: NSSize(width: 472, height: 384), count: 12, corner: corner, cellSize: NSSize(width: 112, height: 120))
            #expect(geometry.columns == 4 && geometry.rows == 3)
            let first = geometry.frame(for: 0)
            #expect(first.minX == (corner.startsOnRight ? 348 : 12))
            #expect(first.minY == (corner.startsAtBottom ? 252 : 12))
            let second = geometry.frame(for: 1)
            #expect(second.minX == first.minX)
            #expect(second.minY == first.minY + (corner.startsAtBottom ? -120 : 120))
            let nextColumn = geometry.frame(for: geometry.rows)
            #expect(nextColumn.minY == first.minY)
            #expect(nextColumn.minX == first.minX + (corner.startsOnRight ? -112 : 112))
            let frames = (0..<12).map { geometry.frame(for: $0) }
            for (slot, frame) in frames.enumerated() {
                #expect(geometry.slot(at: NSPoint(x: frame.midX, y: frame.midY)) == slot)
                #expect(NSRect(origin: .zero, size: geometry.contentSize).contains(frame))
                #expect(frames.enumerated().allSatisfy { $0.offset == slot || !$0.element.intersects(frame) })
            }
            #expect(geometry.slot(at: NSPoint(x: -10, y: 10)) == nil)
        }
        let small = DesktopGridGeometry(
            viewport: NSSize(width: 248, height: 264), count: 4, corner: .bottomRight, cellSize: NSSize(width: 112, height: 120))
        #expect(small.slots(count: 4, preferred: [0: 3, 1: 3, 2: 999, 3: -4]) == [3, 0, 1, 2])
        let overflow = DesktopGridGeometry(
            viewport: NSSize(width: 248, height: 100), count: 20, corner: .bottomLeft, cellSize: NSSize(width: 112, height: 120))
        #expect(overflow.capacity >= 20 && overflow.contentSize.height > 100)
        #expect(Set(overflow.slots(count: 20, preferred: [:])).count == 20)
    }

    @Test func oldNameLineOverridesAreIgnoredAndCornersStillPersist() throws {
        Settings.shared.iconsMaxLines = 3
        Settings.store.set(Data("{\"corner\":\"bottomRight\",\"nameLines\":1,\"positions\":{}}".utf8), forKey: DesktopGridPreferences.key)
        let scratch = try Scratch(); let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        #expect(controller.gridPreferences.corner == .bottomRight && controller.grids.first?.maxLabelLines == 3)
        controller.setGridCorner(.bottomLeft)
        #expect(DesktopGridPreferences.load(from: Settings.store).corner == .bottomLeft)
        Settings.store.set(Data("invalid JSON".utf8), forKey: DesktopGridPreferences.key)
        #expect(DesktopGridPreferences.load(from: Settings.store).corner == .topLeft)
    }

    @Test func desktopItemsAndEmptySpaceReceiveWindowServerHitsAndNativeMenus() async throws {
        let scratch = try Scratch()
        _ = try scratch.file("desktop-hit.txt", "unchanged")
        let displays = NSScreen.screens.enumerated().map { DesktopDisplay(id: CGDirectDisplayID($0.offset + 11), frame: $0.element.visibleFrame) }
        try #require(!displays.isEmpty)
        let controller = makeDesktop(location: scratch.url) { displays }
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 1 })
        controller.setDesktopPlacementEnabled(true)
        for display in displays {
            let surface = try #require(controller.desktopWindows[display.id])
            let window = try #require(surface.window)
            let grid = try #require(surface.collectionView)
            window.contentView?.layoutSubtreeIfNeeded()
            grid.relayout()
            window.displayIfNeeded()
            // Ignore ordinary app windows above the desktop without moving or hiding any of them.
            func desktopHit(at local: NSPoint) -> Int {
                let point = window.convertPoint(toScreen: grid.convert(local, to: nil))
                var below = 0
                for _ in 0..<100 {
                    let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
                    if hit == 0 || hit == window.windowNumber { return hit }
                    let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(hit)) as? [[String: Any]]
                    let layer = (info?.first?[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                    if layer < Int(CGWindowLevelForKey(.normalWindow)) { return hit }
                    below = hit
                }
                return -1
            }
            let icon = NSPoint(x: grid.iconRect(0).midX, y: grid.iconRect(0).midY)
            #expect(
                await eventually(3) { desktopHit(at: icon) == window.windowNumber },
                "The desktop icon must receive the real Window Server hit")
            let empty = grid.geometry.frame(for: 1)
            #expect(
                await eventually(3) { desktopHit(at: NSPoint(x: empty.midX, y: empty.midY)) == window.windowNumber },
                "Empty desktop must receive Porpoise's background menu and selection clicks")
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: grid.convert(icon, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            #expect(grid.model.selection == [grid.model.rows[0].item.url])
            let probe = MenuProbe()
            // Observe native ItemListView's menu dispatch without entering a blocking menu-tracking loop.
            grid.delegate = probe
            let rightClick = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: grid.convert(icon, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            window.sendEvent(rightClick)
            #expect(probe.targets == [grid.model.rows[0].item.url])
            let emptyClick = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: grid.convert(NSPoint(x: empty.midX, y: empty.midY), to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
            window.sendEvent(emptyClick)
            #expect(probe.targets.count == 2 && probe.targets.last! == nil)
            grid.delegate = controller
        }
        #expect(scratch.read("desktop-hit.txt") == "unchanged")
    }

    @Test func emptySpaceStartsNativeRubberBandSelection() async throws {
        let scratch = try Scratch()
        _ = try scratch.file("one.txt"); _ = try scratch.file("two.txt")
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let grid = try #require(controller.grids.first)
        let window = try #require(grid.window)
        window.contentView?.layoutSubtreeIfNeeded(); grid.relayout()
        let frame = grid.highlightRect(0)
        let start = NSPoint(x: 1, y: 1)
        let end = NSPoint(x: frame.maxX + 1, y: frame.maxY + 1)
        #expect(grid.index(at: start) == nil)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: grid.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        grid.mouseDown(with: try event(.leftMouseDown, start))
        #expect(grid.rubberStart == start)
        grid.mouseDragged(with: try event(.leftMouseDragged, end))
        #expect(grid.rubberBand != nil && grid.model.selection == [grid.model.rows[0].item.url])
        grid.mouseUp(with: try event(.leftMouseUp, end))
        #expect(grid.rubberStart == nil && grid.rubberBand == nil)
    }

    @Test func mouseDragSwapsGridCellsPersistsAndKeepsFilesAndSelectionOnRefresh() async throws {
        let scratch = try Scratch()
        let first = try scratch.file("one.txt", "original one")
        let second = try scratch.file("two.txt", "original two")
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        let model = try #require(controller.model)
        try #require(await eventually { !model.isLoading && model.rows.count == 2 })
        controller.grids.first?.window?.contentView?.layoutSubtreeIfNeeded()
        let grid = try #require(controller.grids.first)
        grid.relayout()
        let source = grid.iconRect(0)
        let target = grid.geometry.frame(for: 1)
        func event(_ type: NSEvent.EventType, _ rect: NSRect) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: grid.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: grid.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        grid.mouseDown(with: try event(.leftMouseDown, source))
        grid.mouseDragged(with: try event(.leftMouseDragged, target))
        grid.mouseUp(with: try event(.leftMouseUp, target))
        let saved = try #require(controller.gridPreferences.positions[grid.scope])
        #expect(saved[first.absoluteString] == 1 && saved[second.absoluteString] == 0)
        #expect(DesktopGridPreferences.load(from: Settings.store).positions[grid.scope] == saved)
        #expect(grid.registeredDraggedTypes.isEmpty)
        #expect(try String(contentsOf: first, encoding: .utf8) == "original one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "original two")
        _ = try scratch.file("aaa external.txt")
        try #require(await eventually { model.rows.count == 3 })
        grid.relayout()
        let firstIndex = try #require(grid.itemKeys.firstIndex(of: first.absoluteString))
        #expect(grid.slots[firstIndex] == 1)
        #expect(grid.model.selection == [first])
        #expect(Set(grid.slots).count == 3)
        let positions = controller.gridPreferences.positions
        grid.moveItem(at: firstIndex, to: NSPoint(x: -500, y: -500))
        #expect(controller.gridPreferences.positions == positions)
    }

    @Test func displaysKeepIndependentPositionsAndRestoreAfterReenable() async throws {
        let scratch = try Scratch()
        _ = try scratch.file("a.txt")
        _ = try scratch.file("b.txt")
        let controller = makeDesktop(location: scratch.url) {
            [
                DesktopDisplay(id: 11, frame: NSRect(x: 0, y: 0, width: 640, height: 480)),
                DesktopDisplay(id: 22, frame: NSRect(x: 640, y: 0, width: 800, height: 600)),
            ]
        }
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 2 })
        controller.setDesktopPlacementEnabled(true)
        let first = try #require(controller.desktopWindows[11]?.collectionView)
        let second = try #require(controller.desktopWindows[22]?.collectionView)
        first.relayout()
        let target = first.geometry.frame(for: 5)
        first.moveItem(at: 0, to: NSPoint(x: target.midX, y: target.midY))
        let saved = try #require(controller.gridPreferences.positions[first.scope])
        #expect(controller.gridPreferences.positions[second.scope] == nil)
        controller.setDesktopPlacementEnabled(false)
        controller.setDesktopPlacementEnabled(true)
        let replacement = try #require(controller.desktopWindows[11]?.collectionView)
        replacement.relayout()
        #expect(replacement.slots[0] == 5 && controller.gridPreferences.positions[replacement.scope] == saved)
    }

    @Test func namesAndHoverFollowTheBrowserSettingsAndMenusIncludeDeletion() async throws {
        let scratch = try Scratch(); let name = String(repeating: "long filename ", count: 8) + ".txt"
        let file = try scratch.file(name, "unchanged"); let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 1 })
        let grid = try #require(controller.grids.first); let browser = ItemListView(model: grid.model)
        browser.frame = grid.frame; grid.model.selection = [file]
        for lines in [1, 2, 3, 0] {
            Settings.shared.iconsMaxLines = lines
            grid.relayout(); browser.computeLayout(); browser.frames = grid.frames
            #expect(grid.maxLabelLines == browser.maxLabelLines && grid.nameTextRect(0) == browser.nameTextRect(0))
            #expect(
                grid.iconsLabel(name, width: 120, maxLines: grid.maxLabelLines).label
                    == browser.iconsLabel(name, width: 120, maxLines: browser.maxLabelLines).label)
        }
        for tooltips in [false, true] {
            Settings.shared.showToolTips = tooltips
            grid.hoverIndex = nil; browser.hoverIndex = nil; grid.hoverIndex = 0; browser.hoverIndex = 0
            #expect(grid.toolTip == browser.toolTip && (grid.toolTip != nil) == tooltips)
        }
        let menu = controller.desktopMenu(for: 0)
        for title in ["Copy", "Rename…", "Move to Trash", "Delete", "Get Info"] {
            #expect(menu.items.contains { $0.title == title && $0.target === controller })
        }
        #expect(menu.items.first { $0.title == "Delete" }?.isAlternate == false)
        #expect(!menu.items.contains { ["Name Lines", "Show Desktop Mode Controls"].contains($0.title) })
        let corners = try #require(menu.items.first { $0.title == "Start Corner" }?.submenu); corners.performActionForItem(at: 3)
        #expect(controller.gridPreferences.corner == .bottomLeft && scratch.read(name) == "unchanged")
    }

    @Test func deletionUsesExistingConfirmationsAndOnlyActsOnTheSelection() async throws {
        let scratch = try Scratch(); let target = try scratch.file("remove.txt", "remove"); _ = try scratch.file("keep.txt", "keep")
        let controller = makeDesktop(location: scratch.url); defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let operations = FileOperationsController.shared; let originalUI = operations.ui
        let ui = ScriptedUI(confirms: false); operations.ui = ui; defer { operations.ui = originalUI }
        Settings.shared.confirmTrash = true; Settings.shared.confirmDelete = true
        #expect(!controller.validateMenuItem(.make("Delete", #selector(MainWindowController.deleteItem(_:)))))
        controller.model?.selection = [target]
        #expect(controller.validateMenuItem(.make("Delete", #selector(MainWindowController.deleteItem(_:)))))
        controller.moveToTrash(nil); controller.deleteItem(nil)
        #expect(ui.questions.map(\.confirmTitle) == ["Move to Trash", "Delete"])
        #expect(FileManager.default.fileExists(atPath: target.path) && scratch.read("keep.txt") == "keep")
        ui.confirms = true; controller.deleteItem(nil)
        #expect(await eventually(5) { !FileManager.default.fileExists(atPath: target.path) })
        #expect(scratch.read("keep.txt") == "keep")
    }

    @Test func reflowUsesSharedMotionCanBeInterruptedAndStopsOnClose() async throws {
        let previousReduce = Animator.reducesMotion, previousDisplay = FrameClock.followsDisplay, previousStep = FrameClock.frameStep
        defer {
            Animator.reducesMotion = previousReduce
            FrameClock.followsDisplay = previousDisplay
            FrameClock.frameStep = previousStep
        }
        Animator.reducesMotion = { false }
        FrameClock.followsDisplay = false
        FrameClock.frameStep = 0.05
        let scratch = try Scratch()
        _ = try scratch.file("a.txt")
        _ = try scratch.file("b.txt")
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let grid = try #require(controller.grids.first)
        grid.layoutSubtreeIfNeeded()
        grid.relayout()
        let original = grid.shownFrame(0)
        controller.setGridCorner(.topRight)
        #expect(grid.isAnimating)
        #expect(grid.shownFrame(0) == original)
        try #require(
            await eventually {
                let current = grid.shownFrame(0)
                return grid.isAnimating && current != original && current != grid.geometry.frame(for: grid.slots[0])
            })
        let interrupted = grid.shownFrame(0)
        controller.setGridCorner(.bottomLeft)
        #expect(grid.shownFrame(0) == interrupted)
        try #require(await eventually { !grid.isAnimating })
        #expect(grid.shownFrame(0) == grid.geometry.frame(for: grid.slots[0]))
        Animator.reducesMotion = { true }
        controller.setGridCorner(.topLeft)
        #expect(!grid.isAnimating)
        #expect(grid.shownFrame(0) == grid.geometry.frame(for: grid.slots[0]))
        Animator.reducesMotion = { false }
        controller.setGridCorner(.bottomRight)
        #expect(grid.isAnimating)
        controller.close()
        #expect(!grid.isAnimating)
    }
    @Test func desktopUsesTheBrowserRendererAndNativeMultipleSelection() async throws {
        let scratch = try Scratch()
        let first = try scratch.file("one.txt", "one")
        let second = try scratch.file("two.txt", "two")
        Settings.shared.iconsMaxLines = 3
        let model = try await DirectoryModel.loaded(scratch.url) { $0.props.mode = .icons }
        let desktop = DesktopGridView(model: model)
        desktop.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        desktop.relayout()
        let browser = ItemListView(model: model)
        browser.frame = desktop.frame
        browser.computeLayout()
        // Placement is the desktop's customization; the item itself must be exactly the browser's drawing.
        browser.frames = desktop.frames
        #expect(desktop.font == browser.font && desktop.iconSize == browser.iconSize && desktop.maxLabelLines == browser.maxLabelLines)
        func pixels(_ view: ItemListView) throws -> Data { try #require(view.picture(ofRow: 0)?.dataProvider?.data) as Data }
        #expect(try pixels(desktop) == pixels(browser))
        model.selection = [first]
        #expect(try pixels(desktop) == pixels(browser))
        let window = NSWindow(contentRect: desktop.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = desktop
        defer { window.close() }
        func click(_ index: Int, modifiers: NSEvent.ModifierFlags) throws {
            let icon = desktop.iconRect(index)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: desktop.convert(NSPoint(x: icon.midX, y: icon.midY), to: nil),
                    modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: 1))
            desktop.mouseDown(with: event)
            desktop.mouseUp(with: event)
        }
        try click(0, modifiers: [])
        try click(1, modifiers: .command)
        #expect(model.selection == [first, second])
        #expect(desktop.registeredDraggedTypes.isEmpty)
    }

    @Test func desktopAndBrowserBuildTheSameCommonCommandsAndShortcuts() async throws {
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = AppDelegate.shared.buildMainMenu()
        MenuCommandRegistry.shared.refresh(fillDynamic: false)
        defer { NSApp.mainMenu = previousMenu; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        Settings.shared.setContextMenu(.deleteAlongsideTrash, true)
        let scratch = try Scratch()
        let file = try scratch.file("notes.txt", "unchanged")
        let desktop = makeDesktop(location: scratch.url)
        let browser = MainWindowController(urls: [scratch.url])
        defer { desktop.close(); browser.close() }
        try #require(await eventually { desktop.model?.rows.count == 1 && browser.view.model.rows.count == 1 })
        desktop.model?.selection = [file]; browser.view.model.selection = [file]
        let native = browser.contextMenu(for: browser.view.model.rows[0].item, in: browser.view)
        let surface = desktop.desktopMenu(for: 0)
        for title in ["Cut", "Copy", "Copy Location", "Duplicate Here", "Rename…", "Quick Look", "Get Info", "Move to Trash", "Delete"] {
            let expected = try #require(native.items.first { $0.title == title })
            let actual = try #require(surface.items.first { $0.title == title })
            #expect(actual.action == expected.action && actual.keyEquivalent == expected.keyEquivalent, "\(title)")
            #expect(actual.keyEquivalentModifierMask == expected.keyEquivalentModifierMask, "\(title)")
            #expect(actual.image?.tiffRepresentation == expected.image?.tiffRepresentation)
            #expect(actual.target === desktop)
        }
        let background = desktop.desktopMenu(for: nil)
        #expect(background.items.contains { $0.action == #selector(MainWindowController.createFolder(_:)) && $0.target === desktop })
        #expect(background.items.contains { $0.action == #selector(MainWindowController.paste(_:)) && $0.target === desktop })
    }

    @Test func nativePasteAndInlineRenameWorkOnScratchFilesAndKeepTheGridPosition() async throws {
        let scratch = try Scratch()
        let source = try scratch.file("source.txt", "unchanged")
        let destination = try scratch.folder("Desktop")
        let operations = FileOperationsController.shared
        let previousClipboard = operations.clipboard
        operations.clipboard = LocalClipboard()
        defer { operations.clipboard = previousClipboard }
        let controller = makeDesktop(location: destination)
        defer { controller.close() }
        Settings.shared.renameInline = true
        try #require(await eventually { controller.model?.isLoading == false })
        controller.setDesktopPlacementEnabled(true)
        let grid = try #require(controller.desktopWindows.values.first?.collectionView)
        controller.activeGrid = grid
        grid.window?.makeKey()
        grid.window?.makeFirstResponder(grid)
        operations.copy([source], cut: false)
        let menu = controller.desktopMenu(for: nil)
        let paste = try #require(menu.items.firstIndex { $0.action == #selector(MainWindowController.paste(_:)) })
        menu.performActionForItem(at: paste)
        let copied = destination.appendingPathComponent("source.txt")
        try #require(await eventually(5) { controller.model?.rows.contains { $0.item.url == copied } == true })
        #expect(try String(contentsOf: copied, encoding: .utf8) == "unchanged")
        controller.model?.selection = [copied]
        controller.activeGrid = grid
        grid.moveItem(at: 0, to: NSPoint(x: grid.geometry.frame(for: 3).midX, y: grid.geometry.frame(for: 3).midY))
        controller.renameItem(nil)
        let field = try #require(grid.renameField)
        #expect(grid.onDesktop && grid.window?.canBecomeKey == true)
        #expect(grid.window?.firstResponder is NSTextView || grid.window?.firstResponder === field)
        field.stringValue = "renamed.txt"
        grid.commitRename()
        let renamed = destination.appendingPathComponent("renamed.txt")
        try #require(await eventually(5) { controller.model?.rowNames.contains("renamed.txt") == true })
        #expect(!FileManager.default.fileExists(atPath: copied.path) && scratch.read("source.txt") == "unchanged")
        #expect(controller.gridPreferences.positions[grid.scope]?[renamed.absoluteString] == 3)
        #expect(controller.validateMenuItem(.make("Delete", #selector(MainWindowController.deleteItem(_:)))))
    }

    @Test func sortingUsesTheNativeMenuAndCanArrangeAnAlreadySelectedSort() async throws {
        let scratch = try Scratch()
        _ = try scratch.file("a.txt", "a")
        _ = try scratch.file("z.txt", "z")
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let grid = try #require(controller.grids.first)
        let second = grid.geometry.frame(for: 1)
        grid.moveItem(at: 0, to: NSPoint(x: second.midX, y: second.midY))
        #expect(grid.slots == [1, 0])
        let menu = controller.desktopMenu(for: nil)
        let sort = try #require(menu.items.first { $0.title == "Sort By" }?.submenu)
        let name = try #require(sort.items.firstIndex { $0.representedObject as? String == ItemRole.name.rawValue })
        sort.performActionForItem(at: name)
        #expect(grid.slots == [0, 1] && controller.gridPreferences.positions[grid.scope] == nil)
        let reverse = try #require(sort.items.firstIndex { $0.action == #selector(MainWindowController.setSortDescending(_:)) })
        sort.performActionForItem(at: reverse)
        #expect(controller.model?.rowNames == ["z.txt", "a.txt"] && grid.slots == [0, 1])
        #expect(scratch.read("a.txt") == "a" && scratch.read("z.txt") == "z")
    }

    @Test func arrowsFollowTheVisibleGridFromAllFourCorners() async throws {
        let scratch = try Scratch()
        for name in ["a", "b", "c", "d"] { _ = try scratch.file(name) }
        let model = try await DirectoryModel.loaded(scratch.url) { $0.props.mode = .icons }
        let grid = DesktopGridView(model: model)
        grid.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        for corner in DesktopGridCorner.allCases {
            grid.corner = corner; grid.relayout(); grid.select(model.rows[0].item.url, scroll: false)
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, characters: corner.startsAtBottom ? KeyEquivalent.up : KeyEquivalent.down,
                    charactersIgnoringModifiers: corner.startsAtBottom ? KeyEquivalent.up : KeyEquivalent.down,
                    isARepeat: false, keyCode: corner.startsAtBottom ? 126 : 125))
            grid.keyDown(with: event)
            #expect(model.selection == [model.rows[1].item.url])
        }
    }

    private func shortcutApplication(_ scratch: Scratch) throws -> URL {
        let contents = try scratch.folder("Applications/Test App.app/Contents")
        let info = ["CFBundleIdentifier": "app.porpoise.shortcut-test", "CFBundleName": "Test App", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return contents.deletingLastPathComponent()
    }

    @Test func applicationShortcutUsesNativeAliasRenderingAndOpening() async throws {
        let scratch = try Scratch()
        let application = try shortcutApplication(scratch)
        let desktop = try scratch.folder("Desktop")
        let controller = makeDesktop(location: desktop)
        defer { controller.close() }
        let menu = controller.desktopMenu(for: nil)
        #expect(menu.items.contains { $0.title == "Add Application Shortcut…" && $0.target === controller })
        let alias = try controller.createApplicationShortcut(to: application)
        #expect(alias.lastPathComponent == "Test App" && alias.deletingLastPathComponent().path == desktop.path)
        #expect(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        #expect(try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting]).standardizedFileURL == application.standardizedFileURL)
        try #require(await eventually { controller.model?.rows.count == 1 })
        let item = try #require(controller.model?.rows.first?.item)
        #expect(item.isAliasFile && !item.isBrowsableFolder && controller.model?.selection == [alias])
        let grid = try #require(controller.grids.first)
        let rendered = DesktopGridView(model: grid.model)
        rendered.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        rendered.relayout()
        let browser = ItemListView(model: grid.model)
        browser.frame = rendered.frame; browser.computeLayout(); browser.frames = rendered.frames
        let desktopPixels = try #require(rendered.picture(ofRow: 0)?.dataProvider?.data) as Data
        let browserPixels = try #require(browser.picture(ofRow: 0)?.dataProvider?.data) as Data
        #expect(desktopPixels == browserPixels)
        #expect(controller.desktopMenu(for: 0).items.contains { $0.title == "Show Original" && $0.target === controller })
        var opened: [URL] = []
        controller.localFileOpening.open = { opened.append($0) }
        let browsersBefore = AppDelegate.shared.windows.count
        Settings.shared.desktopFoldersInTabs = true
        Settings.shared.desktopOpenMaximized = true
        controller.itemList(grid, open: [item], inNewTab: false)
        #expect(opened == [alias] && AppDelegate.shared.windows.count == browsersBefore)
    }

    @Test func duplicateShortcutsDoNotOverwriteAndRemovingAnAliasKeepsTheApp() async throws {
        let scratch = try Scratch()
        let application = try shortcutApplication(scratch)
        let originalInfo = try Data(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
        let desktop = try scratch.folder("Desktop")
        let controller = makeDesktop(location: desktop)
        defer { controller.close() }
        let first = try controller.createApplicationShortcut(to: application)
        let originalAlias = try Data(contentsOf: first)
        let second = try controller.createApplicationShortcut(to: application)
        #expect(first.lastPathComponent == "Test App" && second.lastPathComponent == "Test App 2")
        #expect(try Data(contentsOf: first) == originalAlias)
        #expect(
            try URL(resolvingAliasFileAt: second, options: [.withoutUI, .withoutMounting]).standardizedFileURL == application.standardizedFileURL)
        try #require(await eventually { controller.model?.rows.count == 2 })
        let operations = FileOperationsController.shared, previousUI = operations.ui
        let ui = ScriptedUI(confirms: true); operations.ui = ui
        defer { operations.ui = previousUI }
        controller.model?.selection = [first]
        controller.deleteItem(nil)
        try #require(await eventually { !FileManager.default.fileExists(atPath: first.path) && ui.finishedActivities == 1 })
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(try Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")) == originalInfo)
    }

    @Test func shortcutChooserBackendRejectsNonAppsAndClosedDesktops() throws {
        let scratch = try Scratch()
        let desktop = try scratch.folder("Desktop")
        let controller = makeDesktop(location: desktop)
        defer { controller.close() }
        let script = try scratch.file("not-an-app.command", "echo fixture")
        #expect(throws: CocoaError.self) { try controller.createApplicationShortcut(to: script) }
        #expect(throws: CocoaError.self) { try controller.createApplicationShortcut(to: URL(string: "https://example.com/Fake.app")!) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path).isEmpty)
        let application = try shortcutApplication(scratch)
        controller.close()
        #expect(throws: CocoaError.self) { try controller.createApplicationShortcut(to: application) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path).isEmpty)
    }

    @Test func browserMakeAliasRetainsItsNameDestinationAndTarget() async throws {
        let scratch = try Scratch()
        let original = try scratch.file("notes.txt", "unchanged")
        let browser = MainWindowController(urls: [scratch.url])
        defer { browser.close() }
        try #require(await eventually { browser.view.model.rows.count == 1 })
        browser.view.model.selection = [original]
        browser.makeAlias(nil)
        let alias = scratch.path("notes.txt alias")
        #expect(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        #expect(try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting]).standardizedFileURL == original.standardizedFileURL)
        #expect(scratch.read("notes.txt") == "unchanged")
    }

    @Test func hidingAndRestylingTheMenuIconKeepsTheDesktopAlive() throws {
        let scratch = try Scratch()
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        let model = try #require(controller.model)
        let surface = try #require(controller.desktopWindows[11]?.window)
        let original = try #require(controller.statusItem)
        #expect(original.button?.image?.isTemplate == false)
        Settings.shared.desktopMonochromeMenuBarIcon = true
        #expect(controller.statusItem === original && original.button?.image?.isTemplate == true)
        for _ in 0..<2 {
            Settings.shared.desktopShowMenuBarIcon = false
            #expect(controller.statusItem == nil && controller.model === model && surface.isVisible && controller.desktopPlacementEnabled)
            Settings.shared.desktopShowMenuBarIcon = true
            #expect(controller.statusItem != nil && controller.statusItem?.button?.image?.isTemplate == true)
        }
        let status = try #require(controller.statusItem)
        Settings.shared.desktopMonochromeMenuBarIcon = false
        #expect(controller.statusItem === status && status.button?.image?.isTemplate == false)
        controller.close()
        Settings.shared.desktopShowMenuBarIcon = false; Settings.shared.desktopShowMenuBarIcon = true
        #expect(controller.statusItem == nil && controller.model == nil && !surface.isVisible)
    }

    @Test func desktopStillPreventsLastWindowQuitWithNoMenuIcon() throws {
        let scratch = try Scratch()
        Settings.shared.desktopShowMenuBarIcon = false
        let mode = DesktopModeController(environment: { .ready }, makeWindow: { makeDesktop(location: scratch.url) })
        mode.start(); mode.setEnabled(true); defer { mode.stop() }
        #expect(mode.isEnabled && mode.windowController?.statusItem == nil)
        #expect(!AppDelegate(desktopMode: mode).applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    @Test func monochromeMenuIconIsATransparentTemplateOfTheAppMark() throws {
        let image = try #require(DesktopWindowController.menuBarIcon(monochrome: true))
        #expect(image.isTemplate && image.size == NSSize(width: 18, height: 18))
        #expect(DesktopWindowController.menuBarIcon(monochrome: false)?.isTemplate == false)
        let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        var opaque = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.alphaComponent > 0.1 {
                    opaque += 1
                    #expect(color.redComponent < 0.01 && color.greenComponent < 0.01 && color.blueComponent < 0.01)
                }
            }
        }
        #expect(opaque > 0 && opaque < bitmap.pixelsWide * bitmap.pixelsHigh / 2)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
    }

    @Test func desktopOptionControlsPersistAndFollowTheirEnabledState() throws {
        let scratch = try Scratch()
        let mode = DesktopModeController(environment: { .ready }, makeWindow: { makeDesktop(location: scratch.url) }); mode.start();
        mode.setEnabled(true)
        defer { mode.stop() }
        let form = FormBuilder(); SettingsPages.desktopMode(form, controller: mode)
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let controls = views(form.view)
        let show = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "Show icon in menu bar" })
        let enabled = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "Enable Desktop Mode" })
        let style = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == ["Color", "Monochrome"] })
        let folders = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == ["New Window", "New Tab"] })
        let size = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == ["Standard", "Maximized"] })
        func choose(_ popup: NSPopUpButton, _ index: Int) throws {
            popup.selectItem(at: index); popup.sendAction(try #require(popup.action), to: popup.target)
        }
        try choose(style, 1); try choose(folders, 1); try choose(size, 1)
        #expect(Settings.store.bool(forKey: "desktopMonochromeMenuBarIcon"))
        #expect(Settings.store.bool(forKey: "desktopFoldersInTabs") && Settings.store.bool(forKey: "desktopOpenMaximized"))
        show.performClick(nil)
        #expect(!style.isEnabled && mode.windowController?.statusItem == nil)
        #expect(!Settings.store.bool(forKey: "desktopShowMenuBarIcon"))
        enabled.performClick(nil)
        #expect(!show.isEnabled && !folders.isEnabled && !size.isEnabled)
        enabled.performClick(nil)
        #expect(show.isEnabled && folders.isEnabled && size.isEnabled && !style.isEnabled)
        show.performClick(nil)
        #expect(style.isEnabled && mode.windowController?.statusItem?.button?.image?.isTemplate == true)
    }

    @Test func desktopFoldersUseNewWindowsOrNativeTabsWithoutChangingTheGlobalPolicy() async throws {
        let scratch = try Scratch()
        let one = try scratch.folder("one"), two = try scratch.folder("two"), three = try scratch.folder("three")
        let controller = makeDesktop(location: scratch.url); defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 3 })
        let app = AppDelegate.shared
        try #require(app.windows.isEmpty)
        defer { for browser in app.windows { browser.close() } }
        let grid = try #require(controller.grids.first)
        func items(_ urls: [URL]) -> [FileItem] { controller.model!.rows.map(\.item).filter { item in urls.contains { $0.path == item.url.path } } }
        Settings.shared.singleWindow = true
        controller.itemList(grid, open: items([one, two]), inNewTab: false)
        #expect(app.windows.count == 2 && app.windows.allSatisfy { $0.tabs.count == 1 })
        for browser in app.windows { browser.close() }
        Settings.shared.desktopFoldersInTabs = true
        controller.itemList(grid, open: items([one, two]), inNewTab: false)
        let browser = try #require(app.windows.first)
        #expect(app.windows.count == 1 && browser.tabs.count == 2)
        controller.itemList(grid, open: items([three]), inNewTab: false)
        #expect(app.windows.count == 1 && app.windows.first === browser && browser.tabs.count == 3)
        #expect(browser.view.url.path == three.path && Settings.shared.singleWindow)
        let menu = NSMenuItem(); menu.representedObject = one
        controller.ctxOpenInNewWindow(menu)
        #expect(app.windows.count == 2 && app.windows.last !== browser)
        Settings.shared.desktopFoldersInTabs = false
        controller.itemList(grid, open: items([two]), inNewTab: true)
        #expect(app.windows.count == 2 && app.windows.last?.tabs.count == 2)
    }

    /// Whether `window` fills `screen`'s visible area. With Stage Manager's strip shown, macOS keeps a window that
    /// appears clear of the strip on the left, so it fills the rest.
    private func fills(_ window: NSWindow, _ screen: NSScreen) -> Bool {
        let f = window.frame, v = screen.visibleFrame
        if f == v { return true }
        let stageManager = UserDefaults(suiteName: "com.apple.WindowManager")
        guard stageManager?.bool(forKey: "GloballyEnabled") == true, stageManager?.bool(forKey: "AutoHide") != true else { return false }
        return f.minX > v.minX && f.maxX == v.maxX && f.minY == v.minY && f.maxY == v.maxY
    }

    @Test func desktopMaximizedWindowsFillTheChosenScreenAndStandardTabsKeepTheirSize() async throws {
        let scratch = try Scratch()
        let one = try scratch.folder("one"), two = try scratch.folder("two")
        let app = AppDelegate.shared
        try #require(app.windows.isEmpty)
        defer { for browser in app.windows { browser.close() } }
        let screen = try #require(NSScreen.screens.last)
        let opened = app.openDesktopFolders([one], inTabs: true, maximized: true, screen: screen)
        let browser = try #require(opened.first), window = try #require(browser.window)
        #expect(fills(window, screen) && !window.styleMask.contains(.fullScreen))
        let standard = NSRect(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 30, width: 900, height: 650)
        window.setFrame(standard, display: false)
        let actual = window.frame
        let same = app.openDesktopFolders([two], inTabs: true, maximized: false, screen: screen)
        #expect(same.first === browser && window.frame == actual && browser.tabs.count == 2)
        _ = app.openDesktopFolders([one], inTabs: true, maximized: true, screen: screen)
        #expect(fills(window, screen) && !window.styleMask.contains(.fullScreen))
    }

    @Test func desktopSingleClickKeepsTheBrowserMinimizedUntilTheDoubleClickOpensATab() async throws {
        let scratch = try Scratch()
        let first = try scratch.folder("First"), second = try scratch.folder("Second")
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let app = AppDelegate.shared
        try #require(app.windows.isEmpty)
        defer { for browser in app.windows { browser.close() } }
        Settings.shared.desktopFoldersInTabs = true
        let browser = try #require(app.openDesktopFolders([first], inTabs: true, maximized: false).first)
        let browserWindow = try #require(browser.window)
        browserWindow.animationBehavior = .none; browserWindow.miniaturize(nil)
        try #require(await eventually(3) { browserWindow.isMiniaturized })
        let grid = try #require(controller.grids.first), surface = try #require(grid.window)
        surface.contentView?.layoutSubtreeIfNeeded(); grid.relayout()
        let index = try #require(grid.model.rows.firstIndex { $0.item.url.path == second.path })
        let icon = grid.iconRect(index), point = grid.convert(NSPoint(x: icon.midX, y: icon.midY), to: nil)
        func click(_ count: Int) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: Double(count) / 10,
                        windowNumber: surface.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: 1))
                surface.sendEvent(event)
            }
        }
        try click(1)
        await Task.yield()
        #expect(browserWindow.isMiniaturized && browser.tabs.count == 1)
        #expect(grid.model.selection.map(\.path) == [second.path])
        #expect(surface.firstResponder === grid && grid.needsPanelToBecomeKey)
        try click(2)
        #expect(browser.tabs.count == 2 && browser.view.url.path == second.path && app.windows.count == 1)
        #expect(await eventually(3) { !browserWindow.isMiniaturized })
    }

    @Test func repeatedDesktopDoubleClicksAlwaysAddATab() async throws {
        let scratch = try Scratch()
        let folder = try scratch.folder("Folder")
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 1 })
        let app = AppDelegate.shared
        try #require(app.windows.isEmpty)
        defer { for browser in app.windows { browser.close() } }
        Settings.shared.desktopFoldersInTabs = true
        let grid = try #require(controller.grids.first), window = try #require(grid.window)
        window.contentView?.layoutSubtreeIfNeeded(); grid.relayout()
        for (attempt, counts) in [[1, 2], [3, 4], [5, 6], [1, 2]].enumerated() {
            let icon = grid.iconRect(0)
            let point = grid.convert(NSPoint(x: icon.midX, y: icon.midY), to: nil)
            for count in counts {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(
                        NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [], timestamp: Double(attempt) + Double(count) / 10,
                            windowNumber: window.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: 1))
                    window.sendEvent(event)
                }
            }
            #expect(app.windows.count == 1 && app.windows.first?.tabs.count == attempt + 1)
            #expect(app.windows.first?.view.url.path == folder.path)
            await Task.yield()
        }
        let native = ItemListView(model: grid.model), probe = MenuProbe()
        let nativeWindow = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
        nativeWindow.isReleasedWhenClosed = false; nativeWindow.contentView = native
        defer { nativeWindow.close() }
        native.computeLayout(); native.delegate = probe
        let icon = native.iconRect(0)
        let point = native.convert(NSPoint(x: icon.midX, y: icon.midY), to: nil)
        for count in 1...4 {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: Double(count) / 10,
                    windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: 1))
            native.mouseDown(with: event)
        }
        #expect(probe.opened.map(\.path) == [folder.path])
    }

}
