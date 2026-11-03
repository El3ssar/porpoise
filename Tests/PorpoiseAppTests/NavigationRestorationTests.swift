import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct NavigationRestorationTests {
    private final class Source: LocationContentSource {
        let location: URL
        let items: [FileItem]
        var held = false
        var deliveries: [() -> Void] = []
        var traits: LocationTraits { LocationTraits() }
        init(_ location: URL, count: Int) {
            self.location = location
            items = (0..<count).map { FileItem(url: location.appendingPathComponent("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false) }
        }
        func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
            let publish = {
                deliver(LocationListing(items: self.items, entryKeys: Dictionary(uniqueKeysWithValues: self.items.map { ($0.url, $0.url.path) })))
            }
            if held { deliveries.append(publish) } else { publish() }
            return LocationLoad()
        }
        func finish() {
            let ready = deliveries
            deliveries = []
            ready.forEach { $0() }
        }
    }

    private func pane(_ scratch: Scratch) async throws -> (ViewContainer, NSWindow, Source, Source) {
        _ = NSApplication.shared
        Settings.shared.folderSizeMode = .none
        Settings.shared.showGitStatus = false
        var style = ViewProperties()
        style.mode = .details
        style.previews = false
        ViewStyleStore().common = style
        let pane = ViewContainer(url: scratch.url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        try #require(await eventually { !pane.model.isLoading })
        let a = Source(scratch.url.appendingPathComponent("A", isDirectory: true), count: 100)
        let b = Source(scratch.url.appendingPathComponent("B", isDirectory: true), count: 2)
        pane.model.sourceFactory = { url, _ in url.path == a.location.path ? a : b }
        return (pane, window, a, b)
    }

    @Test func quickBackForwardDoesNotOverwriteTheUnfinishedRestoration() async throws {
        let scratch = try Scratch("history-intent")
        let (pane, window, a, b) = try await pane(scratch)
        defer { window.close() }
        pane.setURL(a.location)
        pane.layoutSubtreeIfNeeded()
        let current = a.items[50].url
        pane.model.currentURL = current
        pane.list.scroll(CGPoint(x: 0, y: 600))
        let origin = pane.list.visibleRect.origin
        try #require(origin.y > 0)
        pane.setURL(b.location)
        a.held = true
        pane.goBack()
        #expect(pane.model.isLoading && pane.scrollOrigin == origin)
        pane.goForward()
        pane.goBack()
        #expect(pane.model.isLoading && pane.scrollOrigin == origin)
        a.finish()
        #expect(!pane.model.isLoading && pane.model.currentURL == current)
        #expect(pane.list.visibleRect.origin == origin)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test(arguments: [false, true])
    func deferredColumnSelectionBelongsToItsOriginalVisit(changeVisit: Bool) async throws {
        let scratch = try Scratch("column-history-generation")
        let (pane, window, a, b) = try await pane(scratch)
        defer { window.close() }
        a.held = true
        b.held = true
        pane.setURL(a.location)
        let browser = ColumnBrowserView(container: pane)
        let old = a.items[0].url
        browser.apply(
            .init(root: a.location, focused: a.location, sizes: [], previewWidth: nil, selection: [old], current: old, anchor: old, origins: [:]))
        if changeVisit {
            pane.setURL(b.location)
            pane.setURL(a.location)
        }
        a.finish()
        #expect(!pane.model.isLoading)
        if changeVisit {
            #expect(pane.model.selection.isEmpty && pane.model.currentURL == nil && pane.model.anchorURL == nil)
        } else {
            #expect(pane.model.selection == [old] && pane.model.currentURL == old && pane.model.anchorURL == old)
        }
        #expect(!window.isVisible && !window.isKeyWindow)
    }
}
