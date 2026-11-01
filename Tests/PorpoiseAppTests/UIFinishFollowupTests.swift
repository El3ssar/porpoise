import AVKit
import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct UIFinishFollowupTests {
    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private final class MenuHost: AppsViewHost {
        let model: DirectoryModel
        var selectionWhenMenuBuilt: Set<URL>?
        init(model: DirectoryModel) { self.model = model }
        func appsViewDidBecomeActive(_ v: AppsView) {}
        func appsView(_ v: AppsView, open items: [FileItem]) {}
        func appsView(_ v: AppsView, menuFor item: FileItem?) -> NSMenu? {
            selectionWhenMenuBuilt = model.selection
            return nil  // Inspect composition without entering a native menu tracking loop.
        }
        func appsViewQuickLook(_ v: AppsView) {}
        func appsView(_ v: AppsView, hovered item: FileItem?) {}
    }

    @Test func applicationAccessibilitySelectsBeforeComposingItsContextMenu() async throws {
        let scratch = try Scratch()
        let one = try scratch.file("One.app"), two = try scratch.file("Two.app"), three = try scratch.file("Three.app")
        let model = try await DirectoryModel.loaded(scratch.url)
        let apps = AppsView(model: model), host = MenuHost(model: model)
        apps.host = host
        apps.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        let window = NSWindow(contentRect: apps.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = apps
        defer { window.close() }
        apps.layoutSubtreeIfNeeded()
        apps.reload()
        model.selection = [two, three]
        let children = try #require(apps.grid.accessibilityChildren() as? [AccessibleRegion])
        let element = try #require(children.first { $0.accessibilityLabel() == "One" })
        #expect(!element.accessibilityPerformShowMenu())
        #expect(host.selectionWhenMenuBuilt == [one])
        #expect(model.selection == [one])
    }

    @Test func compactPlaybackControlsKeepEveryVisibleControlInsideTheirBounds() {
        for width in [64.0, 116, 159, 160, 204, 280] {
            let controls = MediaControls(frame: CGRect(x: 0, y: 0, width: width, height: 30))
            controls.layout()
            let visible = controls.subviews.filter { !$0.isHidden }
            for view in visible {
                #expect(view.frame.minX >= 0 && view.frame.maxX <= width)
                #expect(view.frame.minY >= 0 && view.frame.maxY <= 30)
            }
            for (index, view) in visible.enumerated() {
                for other in visible.dropFirst(index + 1) { #expect(!view.frame.intersects(other.frame)) }
            }
        }
    }

    @Test func playbackSliderArrowKeysSeekByTimeAndExposeTheRequestedPosition() throws {
        _ = NSApplication.shared
        let controls = MediaControls(frame: CGRect(x: 0, y: 0, width: 120, height: 30))
        let player = AVPlayer()
        controls.attach(player, duration: 120)
        defer { controls.detach() }
        controls.layout()
        let slider = try #require(descendant(NSSlider.self, in: controls))
        let right = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
        slider.keyDown(with: right)
        #expect(abs(slider.doubleValue - 5.0 / 120) < 0.0001)
        #expect(slider.accessibilityValueDescription() == "0:05 of 2:00")
        let optionRight = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
        slider.keyDown(with: optionRight)
        #expect(abs(slider.doubleValue - 35.0 / 120) < 0.0001)
        #expect(slider.accessibilityValueDescription() == "0:35 of 2:00")
    }

    @Test func inspectorFocusLoopReachesPlayAndSeekAndShortPreviewUsesFullWidthControls() async throws {
        _ = NSApplication.shared
        let previous = KeyboardAccess.isFull
        KeyboardAccess.isFull = { true }
        defer { KeyboardAccess.isFull = previous }
        let scratch = try Scratch()
        let wc = MainWindowController(urls: [scratch.url])
        defer { wc.window?.close() }
        wc.showInformation = true
        wc.rebuildPanels()
        try #require(await eventually { !wc.view.model.isLoading })
        let panel = wc.information
        panel.frame = CGRect(x: 0, y: 0, width: 280, height: 200)
        let playerView = try #require(descendant(AVPlayerView.self, in: panel))
        let controls = try #require(descendant(MediaControls.self, in: panel))
        let player = AVPlayer()
        playerView.player = player
        controls.attach(player, duration: 120)
        defer { controls.detach(); playerView.player = nil }
        panel.layout()
        controls.layout()
        #expect(!controls.isHidden && controls.frame.width > 200)
        let stops = MainWindowController.keyViews(in: panel)
        #expect(stops.count == 3 && stops.first === panel)
        let play = try #require(stops.dropFirst().first as? NSButton)
        let slider = try #require(stops.last as? NSSlider)
        #expect(wc.keyLoopStop(after: panel, backwards: false) === play)
        #expect(wc.keyLoopStop(after: play, backwards: false) === slider)
    }
    @Test func tabResizeRevealsTheActiveTabWithoutOverridingDeliberateWheelScroll() throws {
        let bar = TabBarView(frame: CGRect(x: 0, y: 0, width: 1000, height: TabBarView.height))
        bar.titles = (1...100).map { "Folder \($0)" }
        bar.selected = 99
        bar.layout()
        bar.frame.size.width = 520
        bar.layout()
        func visibleTitles() -> [String] {
            (bar.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        }
        #expect(visibleTitles().contains("Folder 100"))
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        let wheel = try #require(NSEvent(cgEvent: cg))
        bar.scrollWheel(with: wheel)
        let scrolled = visibleTitles()
        #expect(!scrolled.contains("Folder 100"))
        bar.layout()
        #expect(visibleTitles() == scrolled)
    }

    @Test func applicationPresentationSwitchesClearSearchesInBothDirections() async throws {
        _ = NSApplication.shared
        Settings.shared.appLibraryView = true
        Settings.store.set(false, forKey: "applications.showAsFiles")
        let pane = ViewContainer(url: AppLibrary.location)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        defer { window.close() }
        pane.layoutSubtreeIfNeeded()
        let apps = try #require(pane.apps)
        apps.field.stringValue = "UnmatchedApplicationSearch"
        apps.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(pane.model.filter.text == "UnmatchedApplicationSearch")
        pane.setMode(.details)
        #expect(!pane.showsApps && !pane.model.filter.isActive)
        #expect(apps.field.stringValue.isEmpty && !pane.filterBar.filter.isActive)
        pane.filterBar.set(NameFilter(text: "UnmatchedFilesystemFilter"))
        #expect(pane.model.filter.isActive)
        pane.showApplicationLibrary()
        #expect(pane.showsApps && !pane.model.filter.isActive)
        #expect(apps.field.stringValue.isEmpty && !pane.filterBar.filter.isActive)
    }

    @Test func columnPreviewDescendantsExposePlaybackStops() throws {
        _ = NSApplication.shared
        let previous = KeyboardAccess.isFull
        KeyboardAccess.isFull = { true }
        defer { KeyboardAccess.isFull = previous }
        let preview = ColumnPreviewView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview
        defer { window.close() }
        preview.layoutSubtreeIfNeeded()
        let panel = preview.information
        let playerView = try #require(descendant(AVPlayerView.self, in: panel))
        let controls = try #require(descendant(MediaControls.self, in: panel))
        let player = AVPlayer()
        playerView.player = player
        controls.attach(player, duration: 120)
        defer { controls.detach(); playerView.player = nil }
        panel.layout()
        controls.layout()
        let stops = MainWindowController.keyViews(in: preview)
        #expect(stops.count == 3)
        #expect(stops.contains { $0 === panel })
        #expect(stops.contains { $0 is NSButton })
        #expect(stops.contains { $0 is NSSlider })
    }

    @Test func pausedVideoDiscoversItsDurationAndEnablesSeekingWithoutPlayback() async throws {
        _ = NSApplication.shared
        let controls = MediaControls(frame: CGRect(x: 0, y: 0, width: 280, height: 30))
        let player = AVPlayer()
        controls.attach(player, duration: nil)
        defer { controls.detach(); player.replaceCurrentItem(with: nil) }
        let slider = try #require(descendant(NSSlider.self, in: controls))
        #expect(!slider.isEnabled)
        let item = AVPlayerItem(url: TestPaths.fixtures.appendingPathComponent("Videos/h264.mp4"))
        player.replaceCurrentItem(with: item)
        try #require(await eventually(10) { item.status == .readyToPlay && slider.isEnabled })
        #expect(player.timeControlStatus == .paused && player.rate == 0)
        let duration = item.duration.seconds
        #expect(duration.isFinite && duration > 0)
        #expect(slider.accessibilityValueDescription() == "0:00 of \(MediaControls.format(duration))")
        let total = controls.subviews.compactMap { $0 as? NSTextField }.last
        #expect(total?.stringValue == MediaControls.format(duration))
    }

}
