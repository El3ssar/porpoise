import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import ServiceManagement
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct DesktopLoginItemTests {
    init() { _ = NSApplication.shared }

    private func mode(_ folder: URL) -> DesktopModeController {
        DesktopModeController {
            DesktopWindowController(location: folder, displays: { [DesktopDisplay(id: 11, frame: NSRect(x: 0, y: 0, width: 640, height: 480))] })
        }
    }

    @Test func registrationUsesSystemStateAndCanBeRemovedWithoutStoppingTheDesktop() async throws {
        let scratch = try Scratch(), desktop = mode(scratch.url)
        desktop.start(); defer { desktop.stop() }
        var status = SMAppService.Status.notRegistered, registrations = 0, removals = 0, settings = 0
        let login = DesktopLoginItem(
            available: { true }, status: { status },
            register: {
                registrations += 1; status = .requiresApproval
            },
            unregister: {
                removals += 1; status = .notRegistered
            }, openSettings: { settings += 1 })
        #expect(!login.isRegistered)
        await login.setEnabled(true)
        #expect(login.isRegistered && status == .requiresApproval && registrations == 1 && !login.isChanging)
        #expect(login.statusLine.0 == false && login.statusLine.1.contains("Allow Porpoise"))
        login.showSystemSettings(); #expect(settings == 1)
        status = .enabled
        #expect(login.isRegistered && login.statusLine.0 == true)
        await login.setEnabled(true)
        #expect(registrations == 1)
        await login.setEnabled(false)
        #expect(!login.isRegistered && removals == 1 && desktop.isEnabled && !Settings.shared.desktopModeDisabled)
    }

    @Test func errorsDoNotPretendLoginStartupIsEnabledAndCanBeRetried() async {
        var status = SMAppService.Status.notRegistered, shouldFail = true
        let login = DesktopLoginItem(
            available: { true }, status: { status },
            register: {
                if shouldFail { throw CocoaError(.fileWriteNoPermission) }
                status = .enabled
            }, unregister: { throw CocoaError(.fileWriteNoPermission) })
        await login.setEnabled(true)
        #expect(!login.isRegistered && login.error != nil && !login.isChanging && login.statusLine.0 == false)
        shouldFail = false
        await login.setEnabled(true)
        #expect(login.isRegistered && login.error == nil)
        await login.setEnabled(false)
        #expect(login.isRegistered && login.error != nil && !login.isChanging)
    }

    @Test func unavailableBuildsNeverReadOrChangeTheSystemRegistration() async {
        var reads = 0, changes = 0
        let login = DesktopLoginItem(
            available: { false },
            status: {
                reads += 1; return .enabled
            }, register: { changes += 1 },
            unregister: { changes += 1 }, openSettings: { changes += 1 })
        #expect(!login.isAvailable && !login.isRegistered)
        await login.setEnabled(true); await login.setEnabled(false); login.showSystemSettings()
        #expect(reads == 0 && changes == 0 && !login.isChanging)
        #expect(!DesktopLoginItem.shared.isAvailable)
    }

    @Test func onlyInstalledMainBundlesMayRegister() {
        let id = "app.porpoise.Porpoise"
        func allowed(_ path: String, _ identifier: String? = "app.porpoise.Porpoise", testing: Bool = false) -> Bool {
            DesktopLoginItem.canRegister(bundle: URL(fileURLWithPath: path), identifier: identifier, testing: testing)
        }
        #expect(allowed("/Applications/Porpoise.app"))
        #expect(allowed("/Applications/Utilities/Porpoise.app"))
        let userApp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Porpoise.app")
        #expect(allowed(userApp.path))
        #expect(!allowed("/Applications/Porpoise.app", id, testing: true))
        #expect(!allowed("/Applications/Prototype.app", "app.porpoise.DesktopPrototype"))
        #expect(!allowed("/Applications/Porpoise.app", nil))
        #expect(!allowed("/Applications-other/Porpoise.app") && !allowed("/tmp/Porpoise.app") && !allowed("/Applications/Porpoise"))
    }

    @Test func loginDetectionRequiresTheActualOpeningEventAndLoginMarker() {
        func event(_ id: AEEventID = AEEventID(kAEOpenApplication), login: Bool = true) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: id, targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            if login { event.setParam(.init(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData)) }
            return event
        }
        #expect(DesktopLoginItem.wasLaunchedAtLogin(event()))
        #expect(!DesktopLoginItem.wasLaunchedAtLogin(nil) && !DesktopLoginItem.wasLaunchedAtLogin(event(login: false)))
        #expect(!DesktopLoginItem.wasLaunchedAtLogin(event(AEEventID(kAEReopenApplication))))
        #expect(!DesktopLoginItem.wasLaunchedAtLogin(event(AEEventID(kAEOpenDocuments))))
    }

    @Test func loginLaunchKeepsOnlyTheDesktopAndPreservesTheSavedSession() async throws {
        let scratch = try Scratch(), desktop = mode(scratch.url)
        desktop.start(); defer { desktop.stop() }
        let app = AppDelegate(desktopMode: desktop)
        Settings.shared.homeURL = scratch.url
        let session = SessionState(windows: [WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: scratch.url))])])
        Settings.store.set(session.stored, forKey: SessionState.key)
        Settings.store.set(true, forKey: AppDelegate.restoringKey)
        let saved = Settings.store.object(forKey: SessionState.key) as? [Data]
        app.openInitialWindows([], desktopOnly: true)
        app.saveSession()
        #expect(app.desktopOnlyLaunch && app.windows.isEmpty && !app.interactiveServicesStarted && desktop.isEnabled)
        #expect(desktop.windowController?.desktopWindows.count == 1)
        #expect(Settings.store.object(forKey: SessionState.key) as? [Data] == saved && Settings.store.bool(forKey: AppDelegate.restoringKey))
        let opened = app.openDesktopFolders([scratch.url], inTabs: true, maximized: false)
        defer { opened.forEach { $0.close() } }
        #expect(app.windows.count == 1 && app.interactiveServicesStarted)
        #expect(opened.first?.view.url.path == scratch.url.path)
    }

    @Test func explicitlyReopeningTheAppRestoresTheDeferredBrowserSession() throws {
        let scratch = try Scratch(), desktop = mode(scratch.url)
        desktop.start(); defer { desktop.stop() }
        let one = try scratch.folder("One"), two = try scratch.folder("Two")
        Settings.shared.homeURL = scratch.url
        let session = SessionState(windows: [
            WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: one)), TabLayout(primary: PaneLayout(url: two))])
        ])
        Settings.store.set(session.stored, forKey: SessionState.key)
        let app = AppDelegate(desktopMode: desktop)
        defer { app.windows.forEach { $0.close() } }
        app.openInitialWindows([], desktopOnly: true)
        #expect(!app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(!app.desktopOnlyLaunch && app.windows.count == 1 && app.windows.first?.tabs.count == 2 && app.interactiveServicesStarted)
        #expect(app.windows.first?.tabs.map { $0.primary.url.path } == [one.path, two.path])
    }

    @Test func loginControlTracksApprovalAndCanBeUncheckedWhileDesktopModeIsDisabled() async throws {
        let scratch = try Scratch(), desktop = mode(scratch.url)
        desktop.start(); defer { desktop.stop() }
        var status = SMAppService.Status.notRegistered
        let login = DesktopLoginItem(
            available: { true }, status: { status }, register: { status = .requiresApproval }, unregister: { status = .notRegistered })
        let form = FormBuilder(); SettingsPages.desktopMode(form, controller: desktop, loginItem: login)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let check = try #require(views(form.view).compactMap { $0 as? NSButton }.first { $0.title == "Start Desktop Mode at Login" })
        #expect(check.isEnabled && check.state == .off)
        check.performClick(nil)
        #expect(await eventually(3) { check.state == .on && status == .requiresApproval })
        desktop.setEnabled(false)
        #expect(check.isEnabled)
        check.performClick(nil)
        #expect(await eventually(3) { check.state == .off && !check.isEnabled })
        desktop.setEnabled(true)
        #expect(check.isEnabled)
        status = .enabled; form.refresh()
        #expect(check.state == .on)
    }
}
