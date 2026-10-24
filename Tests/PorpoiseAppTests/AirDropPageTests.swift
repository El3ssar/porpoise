import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct AirDropPageTests {
    init() { _ = NSApplication.shared }

    @Test func placesGoTabsHistoryAndRestorationStayInsideThePane() async throws {
        let scratch = try Scratch(), file = try scratch.file("selected.txt", "selection")
        let controller = MainWindowController(urls: [scratch.url])
        defer { controller.window?.close() }
        controller.showWindow(nil)
        try #require(await eventually { !controller.view.model.isLoading })
        controller.view.model.selection = [file]
        controller.places(controller.places, open: PlacesModel.airDropURL, newTab: false, splitView: false)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.url == PlacesModel.airDropURL)
        let page = try #require(controller.view.airDropPage)
        #expect(!page.isHidden && controller.view.scroll.isHidden && !controller.view.model.isLoading)
        #expect(controller.view.model.loadError == nil && controller.view.model.rows.isEmpty)
        #expect(controller.view.statusBar.text.contains("AirDrop") && !controller.view.statusBar.allowsZoom)
        #expect(controller.tab.navigators[0].rootIconName == "airdrop")
        #expect(page.selectionButton.isEnabled)
        var sent: [URL] = []
        page.onSend = { urls, _ in sent = urls }
        page.sendSelection()
        #expect(sent == [file])
        controller.view.goBack()
        #expect(controller.view.url.resolvingSymlinksInPath().path == scratch.url.resolvingSymlinksInPath().path)
        controller.view.goForward()
        #expect(controller.view.url == PlacesModel.airDropURL)
        controller.view.goBack()
        controller.goAirDrop(nil)
        #expect(controller.view.url == PlacesModel.airDropURL)
        controller.places(controller.places, open: PlacesModel.airDropURL, newTab: true, splitView: false)
        #expect(controller.tabs.count == 2 && controller.tabs.last?.primary.url == PlacesModel.airDropURL)
        let saved = SessionState(windows: [controller.captureLayout()])
        let restored = try #require(MainWindowController(layout: SessionState(stored: saved.stored).windows[0]))
        defer { restored.window?.close() }
        restored.view.layoutSubtreeIfNeeded()
        #expect(restored.tabs.count == 2 && restored.view.showsAirDrop && restored.view.airDropPage != nil)
        #expect(PlacesModel.airDropURL.folderName == "AirDrop")
        #expect(LocationKind.of(PlacesModel.airDropURL).isVirtual && !restored.view.canGoUp)
    }

    @Test func otherPaneSelectionIsPreferredAndUsesTheExistingCoordinator() async throws {
        let scratch = try Scratch(), file = try scratch.file("send.txt", "original")
        let controller = MainWindowController(urls: [scratch.url], split: [PlacesModel.airDropURL])
        defer { controller.window?.close() }
        controller.showWindow(nil)
        try #require(await eventually { !controller.tab.primary.model.isLoading })
        controller.tab.primary.model.selection = [file]
        let pane = try #require(controller.tab.secondary)
        pane.layoutSubtreeIfNeeded()
        let page = try #require(pane.airDropPage)
        #expect(page.selectionButton.isEnabled)
        var received: [URL] = [], presented = false
        let coordinator = SharingCoordinator(
            prepare: { urls, _ in
                received = urls
                return try await FileOperationsController().prepareForSharing(urls)
            },
            presenter: { session in
                if case .airDrop = session.mode { presented = true }
                session.finish()
            })
        page.onSend = { coordinator.share($0, mode: .airDrop, from: $1) }
        page.sendSelection()
        try #require(await eventually { presented })
        #expect(received == [file] && scratch.read("send.txt") == "original")
        controller.tab.primary.model.selection = []
        #expect(!page.selectionButton.isEnabled)
        let session = SharingSession(mode: .airDrop, anchor: page, rect: page.bounds, successfulShareRetention: 600)
        let service = NSSharingService(title: "Fixture", image: NSImage(size: NSSize(width: 1, height: 1)), alternateImage: nil) {}
        var scope = NSSharingService.SharingContentScope.item
        #expect(session.sharingService(service, sourceWindowForShareItems: [file], sharingContentScope: &scope) === controller.window)
    }

    @Test func airDropKeyboardBindingNavigatesAndChooseFilesUsesItsWindow() async throws {
        let scratch = try Scratch(), controller = MainWindowController(urls: [scratch.url])
        defer { controller.window?.close() }
        controller.showWindow(nil)
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        NSApp.mainMenu = AppDelegate.shared.buildMainMenu()
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == #selector(MainWindowController.goAirDrop(_:)) { return item }
                if let child = item.submenu, let found = find(child) { return found }
            }
            return nil
        }
        let menu = try #require(NSApp.mainMenu)
        let command = try #require(find(menu))
        #expect(command.keyEquivalent == "r" && command.keyEquivalentModifierMask == [.command, .shift])
        command.target = controller
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "R", charactersIgnoringModifiers: "R", isARepeat: false,
                keyCode: 15))
        let pressed = KeyboardShortcut(key: key.charactersIgnoringModifiers ?? "", modifiers: ShortcutModifiers(key.modifierFlags)).normalized
        let binding = KeyboardShortcut(key: command.keyEquivalent, modifiers: ShortcutModifiers(command.keyEquivalentModifierMask)).normalized
        #expect(pressed == binding && controller.validateMenuItem(command))
        let selector = try #require(command.action)
        #expect(NSApp.sendAction(selector, to: controller, from: command))
        controller.view.layoutSubtreeIfNeeded()
        let page = try #require(controller.view.airDropPage)
        let file = try scratch.file("chosen.txt", "original")
        var attached: NSWindow?, sent: [URL] = []
        page.choose = { window, choose in
            attached = window; choose([file])
        }
        page.onSend = { urls, _ in sent = urls }
        page.chooseFiles()
        #expect(attached === controller.window && sent == [file])
        let panel = AirDropPage.fileChooser()
        #expect(panel.allowsMultipleSelection && panel.canChooseDirectories && panel.canChooseFiles)

    }

    @Test func lightDarkAndSplitCaptures() async throws {
        let controller = MainWindowController(urls: [PlacesModel.airDropURL])
        defer { controller.window?.close() }
        let app = NSApplication.shared, original = app.appearance
        defer { app.appearance = original }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        window.setFrame(CGRect(x: 90, y: 90, width: 1120, height: 760), display: true)
        for split in [false, true] {
            if split { controller.tab.openSplit(url: PlacesModel.airDropURL); controller.tab.secondary?.delegate = controller }
            for look in [AppearanceChoice.light, .dark] {
                Settings.shared.appearance = look; app.appearance = Theme.appearance
                Theme.lookChanged(); controller.layoutRoot()
                try #require(
                    await eventually {
                        window.effectiveAppearance.isDark == (look == .dark) && !controller.tab.isSliding
                    })
                window.contentView?.layoutSubtreeIfNeeded()
                for pane in controller.tab.containers {
                    let page = try #require(pane.airDropPage)
                    #expect(!page.isHidden && page.frame.width > 200 && page.frame.height > 200)
                    #expect(page.chooseButton.accessibilityLabel() == "Choose Files…")
                }
                guard let folder = ProcessInfo.processInfo.environment["PORPOISE_AIRDROP_CAPTURES"] else { continue }
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                window.orderFront(nil); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let image = try #require(WindowCapture.image(of: window.windowNumber))
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("airdrop-\(split ? "split" : "single")-\(look.rawValue).png"))
            }
        }
    }
}
