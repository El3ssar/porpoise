import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct SharingTests {
    @Test func copiesSurviveServiceChoiceUntilSuccessFailureOrPickerCancellation() async throws {
        _ = NSApplication.shared
        for outcome in 0..<3 {
            let scratch = try Scratch()
            let staged = try scratch.folder("staged")
            let local = try scratch.file("staged/file 日本語\n'\".txt", "shared")
            let remote = URL(string: "sftp://share.invalid/file")!
            var presented = 0
            let coordinator = SharingCoordinator(
                prepare: { urls, _ in
                    #expect(urls == [remote])
                    return PreparedSharingItems(urls: [local], folder: staged)
                }, presenter: { _ in presented += 1 }, successfulShareRetention: 1)
            let anchor = NSView()
            let session = try #require(coordinator.share([remote], mode: .picker, from: anchor))
            try #require(await eventually { presented == 1 })
            let picker = NSSharingServicePicker(items: [local])
            let service = NSSharingService(title: "Test", image: NSImage(size: NSSize(width: 1, height: 1)), alternateImage: nil) {
                Issue.record("Tests must never perform a sharing service.")
            }
            if outcome == 0 {
                #expect(session.sharingServicePicker(picker, delegateFor: service) === session)
                session.sharingServicePicker(picker, didChoose: service)
                #expect(!session.finished && coordinator.sessions.count == 1 && FileManager.default.fileExists(atPath: local.path))
                session.sharingService(service, didShareItems: [local])
                #expect(FileManager.default.fileExists(atPath: local.path))
            } else if outcome == 1 {
                session.sharingService(service, didFailToShareItems: [local], error: CocoaError(.userCancelled))
            } else {
                session.sharingServicePicker(picker, didChoose: nil)
            }
            #expect(session.finished && session.prepared == nil && coordinator.sessions.isEmpty)
            #expect(await eventually { !FileManager.default.fileExists(atPath: staged.path) })
            session.finish()  // Terminal callbacks may be delivered more than once.
        }
        #expect(SharingSession.successfulShareRetentionInterval == 600)
    }

    @Test func cancellationBeforePreparationCompletesNeverPresents() async throws {
        let scratch = try Scratch(), staged = try scratch.folder("staged")
        let local = try scratch.file("staged/file", "copy")
        var release: CheckedContinuation<Void, Never>?
        var presented = false
        let coordinator = SharingCoordinator(
            prepare: { _, _ in
                await withCheckedContinuation { release = $0 }
                return PreparedSharingItems(urls: [local], folder: staged)
            }, presenter: { _ in presented = true })
        let anchor = NSView()
        let session = try #require(coordinator.share([local], mode: .airDrop, from: anchor))
        try #require(await eventually { release != nil })
        session.finish()
        release?.resume(); release = nil
        #expect(await eventually { !FileManager.default.fileExists(atPath: staged.path) })
        #expect(!presented && coordinator.sessions.isEmpty)
    }

    @Test func browserAndShelfSnapshotTheWholeSelectionForBothSharingModes() async throws {
        let scratch = try Scratch()
        let urls = [try scratch.file("first.txt", "first"), try scratch.file("second 日本語.txt", "second")]
        let controller = MainWindowController(urls: [scratch.url])
        defer { controller.window?.close() }
        try #require(await eventually { !controller.view.model.isLoading })
        controller.view.model.selection = Set(urls)
        var snapshots: [[URL]] = []
        var modes: [SharingCoordinator.Mode] = []
        let coordinator = SharingCoordinator(
            prepare: { urls, _ in
                snapshots.append(urls); return PreparedSharingItems(urls: urls)
            },
            presenter: { session in
                modes.append(session.mode); session.finish()
            })
        controller.shareSelection(mode: .airDrop, sender: nil, using: coordinator)
        controller.view.model.selection = []
        try #require(await eventually { snapshots.count == 1 && coordinator.sessions.isEmpty })
        #expect(Set(snapshots[0]) == Set(urls) && modes == [.airDrop])
        let store = ShelfStore(file: scratch.path("shelf.json"))
        _ = store.add(urls)
        let shelf = ShelfPanel(frame: CGRect(x: 0, y: 0, width: 300, height: 400), store: store)
        shelf.shareChosen(mode: .picker, using: coordinator)
        try #require(await eventually { snapshots.count == 2 && coordinator.sessions.isEmpty })
        #expect(Set(snapshots[1]) == Set(urls) && modes == [.airDrop, .picker])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func sharingAffordancesFitLightDarkAndSplitLayouts() async throws {
        let app = NSApplication.shared, previous = NSApplication.shared.appearance
        defer { app.appearance = previous; Theme.lookChanged() }
        let scratch = try Scratch()
        let folder = try scratch.folder("Files")
        let urls = [try scratch.file("Files/Report 日本語.txt", "report"), try scratch.file("Files/Project Notes.txt", "notes")]
        Settings.shared.toolbarCommands = [.back, .forward, .up, .location, .share, .airDrop, .menu]
        let controller = MainWindowController(urls: [folder])
        let window = try #require(controller.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1100, height: 720))
        let store = ShelfStore(file: scratch.path("shelf.json"))
        _ = store.add(urls)
        controller.shelf = ShelfPanel(frame: .zero, store: store)
        controller.showShelf = true; controller.rebuildPanels()
        try #require(await eventually { !controller.view.model.isLoading })
        controller.view.model.selection = Set(urls)
        func buttons(_ view: NSView) -> [FlatButton] {
            (view as? FlatButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        func hasFlight(_ view: NSView) -> Bool { view is SplitFlightOverlay || view.subviews.contains(where: hasFlight) }
        func settled() -> Bool {
            !controller.tab.isSliding && !hasFlight(controller.root)
                && controller.tab.containers.allSatisfy {
                    !$0.model.isLoading && $0.list.transition == nil && $0.list.transitionHidden.isEmpty
                }
        }
        for split in [false, true] {
            if split { controller.toggleSplit(nil) }
            try #require(await eventually { settled() })
            for look in [AppearanceChoice.light, .dark] {
                Settings.shared.appearance = look; app.appearance = Theme.appearance
                try #require(await eventually { window.effectiveAppearance.isDark == (look == .dark) })
                Theme.lookChanged(); controller.layoutRoot()
                window.contentView?.layoutSubtreeIfNeeded()
                try #require(await eventually { settled() })
                let actions = buttons(controller.toolbar).filter {
                    $0.identifier?.rawValue == ToolbarCommand.share.toolbarIdentifier.rawValue
                        || $0.identifier?.rawValue == ToolbarCommand.airDrop.toolbarIdentifier.rawValue
                }
                #expect(actions.count == 2 && actions.allSatisfy { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 20 })
                #expect(
                    controller.places.rows.contains {
                        if case .entry(let e) = $0.kind { return e.url == PlacesModel.airDropURL }; return false
                    })
                guard let folder = ProcessInfo.processInfo.environment["PORPOISE_SHARING_CAPTURES"] else { continue }
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                window.orderFront(nil); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let image = try #require(WindowCapture.image(of: window.windowNumber))
                let name = "sharing-\(split ? "split" : "single")-\(look.rawValue).png"
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }

    @Test func commandsAndToolbarOfferAirDropAndRemoteSharingWithoutIO() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let controller = MainWindowController(urls: [scratch.url])
        defer { controller.window?.close() }
        let remote = URL(string: "sftp://share.invalid/report.txt")!
        let item = FileItem(url: remote, name: "report.txt", isDirectory: false)
        try #require(await eventually { !controller.view.model.isLoading })
        controller.view.model.apply(ListingEdit(folder: scratch.url, added: [item]))
        controller.view.model.selection = [remote]
        for selector in [#selector(MainWindowController.shareItems(_:)), #selector(MainWindowController.airDropItems(_:))] {
            let menuItem = NSMenuItem(title: "Share", action: selector, keyEquivalent: "")
            #expect(controller.validateMenuItem(menuItem))
            #expect(controller.contextMenu(for: item, in: controller.view).items.contains { $0.action == selector })
        }
        #expect(ToolbarCommand.allCases.contains(.share) && ToolbarCommand.allCases.contains(.airDrop))
        #expect(ToolbarCommand.airDrop.title == "AirDrop…" && ToolbarCommand.share.symbol == "square.and.arrow.up")
        #expect(PlacesPanel.takesDrops([remote, scratch.url], into: PlacesModel.airDropURL))
        #expect(!PlacesPanel.takesDrops([], into: PlacesModel.airDropURL))
        #expect(!PlacesPanel.takesDrops([URL(string: "https://example.invalid")!], into: PlacesModel.airDropURL))
    }
}
