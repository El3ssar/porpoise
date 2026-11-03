import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// A cached folder is usable while its fresh listing is outstanding. Fixtures stay detached from any window.
@MainActor @Suite(.serialized, .isolatedSettings) struct CachedNavigationUITests {
    private final class Source: LocationContentSource {
        let location: URL
        let oldItems: [FileItem]
        var freshItems: [FileItem]
        private var delivery: (id: UUID, send: (LocationListing) -> Void)?
        var traits: LocationTraits { LocationTraits(paintsCache: true) }

        init(location: URL, oldItems: [FileItem], freshItems: [FileItem]) {
            self.location = location
            self.oldItems = oldItems
            self.freshItems = freshItems
        }

        func cached(_ folder: URL) -> [FileItem]? { oldItems }

        func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
            let id = UUID()
            delivery = (id, deliver)
            return LocationLoad { [weak self] in
                if self?.delivery?.id == id { self?.delivery = nil }
            }
        }

        func finish() {
            let send = delivery?.send
            delivery = nil
            send?(LocationListing(items: freshItems))
        }

        func cancel() { delivery = nil }
    }

    private func fixture(_ scratch: Scratch, freshIncludesRequested: Bool) async throws -> (ViewContainer, Source, URL) {
        _ = NSApplication.shared
        let folder = try scratch.folder("destination")
        Settings.shared.folderSizeMode = .none
        Settings.shared.showGitStatus = false
        var style = ViewProperties()
        style.mode = .details
        style.previews = false
        ViewStyleStore().common = style
        let pane = ViewContainer(url: scratch.url)
        pane.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        try #require(await eventually { !pane.model.isLoading })
        let old = FileItem(url: folder.appendingPathComponent("existing.txt"), name: "existing.txt", isDirectory: false, size: 10)
        let requested = FileItem(url: folder.appendingPathComponent("new.txt"), name: "new.txt", isDirectory: false, size: 20)
        let source = Source(location: folder, oldItems: [old], freshItems: freshIncludesRequested ? [old, requested] : [old])
        pane.model.sourceFactory = { _, _ in source }
        return (pane, source, requested.url)
    }

    @Test func revealWaitsForTheFreshListingWhenTheCachePredatesTheFile() async throws {
        let scratch = try Scratch("cached-reveal")
        let (pane, source, requested) = try await fixture(scratch, freshIncludesRequested: true)
        defer { source.cancel() }
        pane.setURL(source.location, selecting: requested)
        #expect(pane.model.isRefreshing && pane.model.rows.map(\.item.name) == ["existing.txt"])
        #expect(pane.pendingSelect == requested && pane.model.selection.isEmpty)
        source.finish()
        try #require(await eventually { !pane.model.isRefreshing && !pane.model.isLoading })
        #expect(pane.pendingSelect == nil)
        #expect(pane.model.currentURL == requested && pane.model.selection == [requested])
        #expect(pane.window == nil)
    }

    @Test func anAbsentRevealRequestExpiresWhenTheFreshListingFinishes() async throws {
        let scratch = try Scratch("cached-missing-reveal")
        let (pane, source, requested) = try await fixture(scratch, freshIncludesRequested: false)
        defer { source.cancel() }
        pane.setURL(source.location, selecting: requested)
        #expect(pane.pendingSelect == requested)
        source.finish()
        try #require(await eventually { !pane.model.isRefreshing && !pane.model.isLoading })
        #expect(pane.pendingSelect == nil && pane.model.selection.isEmpty)
        // The request must not unexpectedly select a similarly named file on a later reload.
        source.freshItems.append(FileItem(url: requested, name: requested.lastPathComponent, isDirectory: false))
        pane.reload()
        source.finish()
        try #require(await eventually { !pane.model.isRefreshing && !pane.model.isLoading })
        #expect(pane.model.index(of: requested) != nil && pane.model.selection.isEmpty)
        #expect(pane.window == nil)
    }

    @Test(arguments: [false, true]) func delayedUpdatingStatusIncludesSelectionsAndClearsAfterRefresh(selected: Bool) async throws {
        let scratch = try Scratch("cached-updating-status")
        let (pane, source, _) = try await fixture(scratch, freshIncludesRequested: true)
        defer { source.cancel() }
        pane.setURL(source.location)
        if selected { pane.list.select(source.oldItems[0].url) }
        #expect(!pane.statusBar.text.contains("Updating…"), "Fast refreshes should not flash a loading notice")
        try #require(await eventually { pane.statusBar.text.contains("Updating…") })
        #expect(pane.model.isRefreshing)
        if selected { #expect(pane.statusBar.text.contains("selected")) }
        try captureUpdatingStatus(pane, selected: selected)
        source.finish()
        try #require(await eventually { !pane.model.isRefreshing && !pane.statusBar.text.contains("Updating…") })
        #expect(pane.window == nil)
    }

    private func captureUpdatingStatus(_ pane: ViewContainer, selected: Bool) throws {
        guard let folder = ProcessInfo.processInfo.environment["PORPOISE_NAVIGATION_CAPTURES"] else { return }
        let previousAppearance = NSApp.appearance
        let previousChoice = Settings.shared.appearance
        defer {
            Settings.shared.appearance = previousChoice
            NSApp.appearance = previousAppearance
            Theme.lookChanged()
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, choice, look) in [
            ("light", AppearanceChoice.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua),
        ] {
            let appearance = try #require(NSAppearance(named: look))
            Settings.shared.appearance = choice
            NSApp.appearance = appearance
            Theme.lookChanged()
            let window = NSWindow(contentRect: pane.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = pane
            defer {
                window.contentView = nil
                window.close()
            }
            pane.layoutSubtreeIfNeeded()
            pane.updateStatus()
            let bitmap = try #require(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
            appearance.performAsCurrentDrawingAppearance { pane.cacheDisplay(in: pane.bounds, to: bitmap) }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("navigation-updating-\(name)-\(selected ? "selected" : "folder").png"))
            #expect(!window.isVisible && !window.isKeyWindow)
            #expect(pane.statusBar.text.contains("Updating…"))
        }
    }
}
