import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct UIFinishTests {
    @Test func compactBarsPreserveEditableInputAndRecoveryFeedback() {
        for width in [160.0, 240, 320, 480, 800] {
            let search = SearchBar(frame: NSRect(x: 0, y: 0, width: width, height: 40))
            search.layout()
            #expect(search.field.frame.minX >= 0 && search.field.frame.maxX <= width)
            #expect(search.field.frame.width >= 72)
            let filter = FilterBar(frame: NSRect(x: 0, y: 0, width: width, height: 62))
            filter.set(NameFilter(text: "[", mode: .regex))
            filter.layout()
            #expect(filter.preferredHeight == 62)
            #expect(filter.field.frame.minX >= 0 && filter.field.frame.maxX <= width)
            #expect(filter.field.frame.width >= 72)
            let error = filter.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Invalid expression" }
            #expect(error?.isHidden == false && (error?.frame.maxY ?? 1000) <= filter.bounds.height)
        }
    }

    @Test func localSearchTooltipsResetAfterACloudVisit() throws {
        let search = SearchBar()
        search.cloudService = "Dropbox"
        search.cloudService = nil
        let buttons = search.subviews.compactMap { $0 as? FlatButton }
        let everywhere = try #require(buttons.first { $0.title == "Everywhere" })
        let contents = try #require(buttons.first { $0.title == "+ Contents" })
        #expect(everywhere.toolTip?.contains("Spotlight") == true)
        #expect(contents.toolTip?.contains("Dropbox") == false)
        let mode = FlatButton(icon: nil, title: "Plain Text")
        mode.title = "Regular Expression"
        #expect(mode.accessibilityLabel() == "Regular Expression")
    }

    @Test func manyTabsKeepSelectionAndNewTabReachable() throws {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: TabBarView.height))
        bar.titles = (1...100).map { "Folder \($0)" }
        bar.selected = 99
        bar.layout()
        let elements = try #require(bar.accessibilityChildren())
        let last = try #require(elements.compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "Folder 100" })
        let plus = try #require(elements.compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "New Tab" })
        for element in [last, plus] {
            let frame = element.accessibilityFrameInParentSpace()
            #expect(frame.width > 0 && frame.minX >= 0 && frame.maxX <= bar.bounds.width)
        }
        #expect(elements.contains { ($0 as? FlatButton)?.toolTip == "Show All Tabs" })
    }

    @Test func longMessagesKeepTheirFullSelectableTextAndSeparateAction() throws {
        let bar = MessageBar()
        let message = String(repeating: "The file could not be copied. Check this destination and try again. ", count: 30)
        bar.show(message, error: true, action: "Try Again") {}
        bar.frame = NSRect(x: 0, y: 0, width: 240, height: bar.preferredHeight(for: 240))
        bar.layout()
        let scroll = try #require(bar.subviews.compactMap { $0 as? NSScrollView }.first)
        let label = try #require(scroll.documentView as? NSTextField)
        #expect(label.stringValue == message && label.isSelectable)
        #expect(label.frame.height > scroll.bounds.height)
        #expect((bar.actionFrame?.maxX ?? 1000) <= bar.bounds.width)
        #expect(bar.bounds.height <= 144)
    }

    @Test func failedCapacityLookupBacksOffAfterCompletionAndRejectsStaleWork() throws {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var cache = VolumeCapacityCache()
        let firstRequest = cache.begin(a, at: now)
        let first = try #require(firstRequest)
        let duplicate = cache.begin(a, at: now)
        #expect(duplicate == nil)
        // Even a slow failed query waits five seconds from completion, not from when it started.
        let failed = cache.finish(a, generation: first, value: nil, at: now.addingTimeInterval(20))
        #expect(failed)
        let tooSoon = cache.begin(a, at: now.addingTimeInterval(24))
        #expect(tooSoon == nil)
        let secondRequest = cache.begin(a, at: now.addingTimeInterval(25))
        let second = try #require(secondRequest)
        let otherRequest = cache.begin(b, at: now.addingTimeInterval(25))
        _ = try #require(otherRequest)
        let thirdRequest = cache.begin(a, at: now.addingTimeInterval(31))
        let third = try #require(thirdRequest)
        let stale = cache.finish(a, generation: second, value: (100, 200), at: now.addingTimeInterval(31))
        #expect(!stale)
        let current = cache.finish(a, generation: third, value: (40, 200), at: now.addingTimeInterval(31))
        #expect(current && cache.value(for: a)?.free == 40)
        let fourthRequest = cache.begin(a, at: now.addingTimeInterval(37))
        let fourth = try #require(fourthRequest)
        let failedAgain = cache.finish(a, generation: fourth, value: nil, at: now.addingTimeInterval(37))
        #expect(failedAgain && cache.value(for: a)?.free == 40)
    }

    @Test func applicationAccessibilityCanSelectWithoutLaunching() async throws {
        let scratch = try Scratch("app-ax-selection")
        _ = try scratch.file("One.app")
        _ = try scratch.file("Two.app")
        let model = try await DirectoryModel.loaded(scratch.url)
        let grid = AppsGridView(model: model)
        grid.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = grid
        defer { window.close() }
        grid.updateLayout(width: 600)
        let children = try #require(grid.accessibilityChildren() as? [AccessibleRegion])
        #expect(children.count == 2)
        children[0].setAccessibilitySelected(true)
        children[1].setAccessibilitySelected(true)
        #expect(model.selection.count == 2)
        children[0].setAccessibilitySelected(false)
        #expect(model.selection.count == 1)
        #expect(children[1].accessibilityRole() == .row)
    }
}
