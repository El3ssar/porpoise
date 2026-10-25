import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import Testing

@testable import Porpoise

/// The first-run welcome is one sheet of two steps on the browser window (the first also offers the key set and the
/// default file browser), and the other permissions are asked for
/// when an action first needs them. These tests replace process-wide permission hooks and read/write Settings.store;
/// take the shared settings turn as well as serializing this suite's own tests.
@MainActor @Suite(.serialized, .isolatedSettings) struct OnboardingTests {
    private func withWelcome(granted: Bool, _ body: (OnboardingWindowController, NSWindow) throws -> Void) throws {
        let saved = (OnboardingWindowController.fullDiskGranted, Settings.store.object(forKey: OnboardingWindowController.doneKey))
        let browser = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        OnboardingWindowController.fullDiskGranted = { granted }
        defer {
            // The sheet first, then the window it's on.
            OnboardingWindowController.shared?.finish()
            browser.orderOut(nil)  // not close(): the last window closed would quit the test host
            OnboardingWindowController.fullDiskGranted = saved.0
            Settings.store.set(saved.1, forKey: OnboardingWindowController.doneKey)
        }
        Settings.store.removeObject(forKey: OnboardingWindowController.doneKey)
        browser.orderFront(nil)
        OnboardingWindowController.show(on: browser)
        let welcome = try #require(OnboardingWindowController.shared)
        try body(welcome, browser)
    }

    /// What a click does (`performClick` runs the button's tracking loop, which ends the test host's run loop).
    private func click(_ b: NSButton) { NSApp.sendAction(b.action!, to: b.target, from: b) }

    private func texts(in view: NSView) -> [String] {
        view.subviews.flatMap { v in ((v as? NSTextField).map { [$0.stringValue] } ?? []) + texts(in: v) }
    }

    @Test func theWelcomeIsASheetOfTwoStepsWithBack() throws {
        #expect(OnboardingWindowController.Step.allCases.count <= 2)
        try withWelcome(granted: false) { welcome, browser in
            #expect(browser.attachedSheet === welcome.window)
            #expect(OnboardingWindowController.debugStep == "welcome")
            #expect(welcome.back.isHidden && welcome.primary.title == "Continue" && welcome.secondary.title == "Skip")
            click(welcome.primary)
            #expect(welcome.step == .fullDisk && !welcome.back.isHidden)
            #expect(welcome.primary.title == "Open System Settings" && !welcome.secondary.isHidden)
            click(welcome.back)
            #expect(welcome.step == .welcome && welcome.back.isHidden)
        }
    }

    /// The welcome step offers the key set and the default file browser; the permissions note names a real place.
    @Test func welcomeOffersTheKeySetAndTheDefaultBrowser() throws {
        let saved = (OnboardingWindowController.setDefaultBrowser, OnboardingWindowController.isDefaultBrowser)
        var isDefault = false
        var asked: [Bool] = []
        OnboardingWindowController.isDefaultBrowser = { isDefault }
        OnboardingWindowController.setDefaultBrowser = { on, done in
            asked.append(on)
            isDefault = on
            done(nil)
        }
        defer { (OnboardingWindowController.setDefaultBrowser, OnboardingWindowController.isDefaultBrowser) = saved }
        Settings.shared.shortcutKeySet = .mac
        try withWelcome(granted: false) { welcome, _ in
            #expect(welcome.keySet.segmentCount == 2 && welcome.keySet.selectedSegment == 0)
            #expect(welcome.keySetHint.stringValue.contains("Return renames"))
            welcome.keySet.selectedSegment = 1
            welcome.keySetChanged(welcome.keySet)
            #expect(Settings.shared.shortcutKeySet == .dolphin && welcome.keySetHint.stringValue.contains("Return opens"))
            #expect(welcome.defaultBrowser.state == .off)
            welcome.defaultBrowser.state = .on
            welcome.defaultBrowserChanged(welcome.defaultBrowser)
            #expect(asked == [true] && welcome.defaultBrowser.state == .on)
            welcome.go(to: .fullDisk)
            let shown = texts(in: try #require(welcome.window?.contentView))
            #expect(shown.contains { $0.contains("Porpoise › Permissions") })
            #expect(!shown.contains { $0.contains("Settings › System") })
        }
        Settings.shared.shortcutKeySet = .mac
    }

    @Test func grantedFullDiskAccessCollapsesToOneLine() throws {
        try withWelcome(granted: true) { welcome, _ in
            welcome.go(to: .fullDisk)
            let shown = texts(in: try #require(welcome.window?.contentView))
            #expect(shown.contains("Full Disk Access is on."))
            #expect(!shown.contains { $0.hasPrefix("Click") || $0.hasPrefix("Switch on") })
            #expect(welcome.primary.title == "Start Using Porpoise" && welcome.secondary.isHidden)
        }
    }

    @Test func skippingClosesWithoutAWarningAndIsntAskedAgain() throws {
        try withWelcome(granted: false) { welcome, browser in
            click(welcome.secondary)
            #expect(browser.attachedSheet == nil)
            #expect(OnboardingWindowController.shared == nil && OnboardingWindowController.debugStep == "none")
            #expect(Settings.store.bool(forKey: OnboardingWindowController.doneKey))
        }
    }

    /// The pager dots read at 3:1 at least on the window background, light and dark; the current one is a capsule.
    @Test func pagerDotsAreVisible() throws {
        func luminance(_ c: NSColor) -> CGFloat {
            let c = c.usingColorSpace(.sRGB)!
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var ratio: CGFloat = 0
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
                let dot = OnboardingWindowController.dotColor.usingColorSpace(.sRGB)!
                // The dot's alpha over the background.
                let a = dot.alphaComponent
                let shown = NSColor(
                    srgbRed: dot.redComponent * a + bg.redComponent * (1 - a), green: dot.greenComponent * a + bg.greenComponent * (1 - a),
                    blue: dot.blueComponent * a + bg.blueComponent * (1 - a), alpha: 1)
                let (l1, l2) = (luminance(shown), luminance(bg))
                ratio = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
            }
            #expect(ratio >= 3, "\(name.rawValue): \(ratio)")
        }
        try withWelcome(granted: false) { welcome, _ in
            let widths = welcome.dots.arrangedSubviews.map(\.frame.width)
            #expect(widths.count == 2 && widths[0] == 16 && widths[1] == 8)
        }
    }

    @Test func appManagementIsAskedTheFirstTimeAnAppIsMoved() {
        let saved = (
            SystemIntegration.FirstNeed.appManagementState, SystemIntegration.FirstNeed.checkAppManagement,
            Settings.store.object(forKey: SystemIntegration.FirstNeed.askedAppManagementKey)
        )
        defer {
            SystemIntegration.FirstNeed.appManagementState = saved.0
            SystemIntegration.FirstNeed.checkAppManagement = saved.1
            Settings.store.set(saved.2, forKey: SystemIntegration.FirstNeed.askedAppManagementKey)
        }
        var state = PrivacyAccess.AccessState.unknown
        var checks = 0, explained = 0
        SystemIntegration.FirstNeed.appManagementState = { state }
        SystemIntegration.FirstNeed.checkAppManagement = { done in
            checks += 1
            state = .denied
            done()
        }
        Settings.store.removeObject(forKey: SystemIntegration.FirstNeed.askedAppManagementKey)
        let app = URL(fileURLWithPath: "/Applications/Some.app"), doc = URL(fileURLWithPath: "/tmp/notes.txt")
        // Copies, and anything that isn't an app, need nothing.
        SystemIntegration.FirstNeed.appManagement(.copy, [app]) { explained += 1 }
        SystemIntegration.FirstNeed.appManagement(.move, [doc]) { explained += 1 }
        #expect(checks == 0 && explained == 0)
        #expect(!SystemIntegration.FirstNeed.touchesApps(.move, [URL(string: "sftp://host/Some.app")!]))
        // The first app moved: checked, and explained since it's off.
        SystemIntegration.FirstNeed.appManagement(.move, [doc, app]) { explained += 1 }
        #expect(checks == 1 && explained == 1)
        // Only once.
        SystemIntegration.FirstNeed.appManagement(.trash, [app]) { explained += 1 }
        #expect(checks == 1 && explained == 1)
        // Already allowed: never asked.
        Settings.store.removeObject(forKey: SystemIntegration.FirstNeed.askedAppManagementKey)
        state = .allowed
        SystemIntegration.FirstNeed.appManagement(.delete, [app]) { explained += 1 }
        #expect(checks == 1 && explained == 1)
    }

    /// Connect (DS-9): tiles wide enough for every name, six across, and services not ready yet on one line, not as tiles.
    @Test func connectTilesFitTheirNamesAndComingSoonIsOneLine() throws {
        let titles = ConnectSheet.ServerKind.allCases.map(\.title) + CloudProvider.allCases.map(\.title)
        for t in titles {
            let width = (t as NSString).size(withAttributes: [.font: ConnectTile.titleFont]).width
            #expect(width <= ConnectTile.size.width - 8, "\(t): \(width)")
        }
        #expect(ConnectTile.size.width == 100)
        let browser = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        browser.orderFront(nil)
        let sheet = ConnectSheet.run(window: browser) { _ in }
        defer {
            sheet.close(nil)
            browser.orderOut(nil)  // not close(): the last window closed would quit the test host
        }
        let content = try #require(sheet.window?.contentView)
        func tiles(_ v: NSView) -> [ConnectTile] { ((v as? ConnectTile).map { [$0] } ?? []) + v.subviews.flatMap(tiles) }
        let ids = Set(tiles(content).compactMap { $0.identifier?.rawValue })
        for p in CloudProvider.allCases { #expect(ids.contains("tile-" + p.rawValue) == p.isAvailable, "\(p)") }
        let later = CloudProvider.allCases.filter { !$0.isAvailable }
        let line = texts(in: content).first { $0.hasPrefix("More services coming") }
        #expect(later.allSatisfy { line?.contains($0.title) == true })
        #expect(content.frame.width >= ConnectTile.rowWidth(ConnectSheet.ServerKind.allCases.count) + 2 * Tokens.Space.xl)
        // UI-5: the page sits on the sheet's 20-pt margins.
        content.layoutSubtreeIfNeeded()
        let page = try #require(content.subviews.first)
        let f = page.frame
        for (edge, value) in [
            ("left", f.minX), ("right", content.bounds.width - f.maxX), ("top", content.bounds.height - f.maxY), ("bottom", f.minY),
        ] {
            #expect(abs(value - Tokens.Space.xl) < 0.5, "\(edge) margin \(value)")
        }
    }
}
