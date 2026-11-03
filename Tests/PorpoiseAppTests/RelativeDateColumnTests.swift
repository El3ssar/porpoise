import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct RelativeDateColumnTests {
    init() { _ = NSApplication.shared }

    @Test func refreshFollowsTheEarliestVisibleMinuteBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let next = ItemListView.nextRelativeDateRefresh(
            dates: [now.addingTimeInterval(-5), now.addingTimeInterval(-119)], now: now, calendar: .current)
        #expect(abs((next?.timeIntervalSince(now) ?? 0) - 1.01) < 0.001)
        #expect(ItemListView.nextRelativeDateRefresh(dates: [], now: now, calendar: .current) == nil)
        let future = ItemListView.nextRelativeDateRefresh(dates: [now.addingTimeInterval(10)], now: now, calendar: .current)
        #expect(abs((future?.timeIntervalSince(now) ?? 0) - 10.01) < 0.001)
    }

    @Test func olderDatesRefreshAtLocalMidnightIncludingDST() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 30)))
        let next = try #require(ItemListView.nextRelativeDateRefresh(dates: [now.addingTimeInterval(-86400)], now: now, calendar: cal))
        #expect(cal.component(.hour, from: next) == 0 && cal.component(.day, from: next) == 26)
        #expect(next.timeIntervalSince(now) == 24.5 * 3600)
    }

    @Test func exactTooltipBelongsToThePointedDateColumn() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let item = FileItem(url: scratch.url.appendingPathComponent("Report.txt"), name: "Report.txt", isDirectory: false, modificationDate: Date())
        model.searchResults = [item]
        model.props.mode = .details
        model.props.setRoles([.size, .modificationTime, .creationTime], for: .details)
        let view = ItemListView(model: model)
        view.frame.size = CGSize(width: 900, height: 300)
        view.computeLayout()
        let x = ItemListView.sidePadding + (view.columnWidths[.name] ?? 0) + (view.columnWidths[.size] ?? 0) + 10
        #expect(view.dateToolTip(at: CGPoint(x: x, y: view.frames[0].midY), row: 0) == "Modified: \(FileFormat.exactDate(item.modificationDate!))")
        #expect(view.dateToolTip(at: CGPoint(x: 30, y: view.frames[0].midY), row: 0) == nil)
        #expect(view.dateToolTip(at: CGPoint(x: x + (view.columnWidths[.modificationTime] ?? 0), y: view.frames[0].midY), row: 0) == nil)
        #expect(view.dateToolTip(at: CGPoint(x: x, y: 0), row: 99) == nil)
    }

    @Test func detachedAndHiddenListsDoNotKeepAClock() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = [FileItem(url: scratch.url.appendingPathComponent("file"), name: "file", isDirectory: false, modificationDate: Date())]
        model.props.mode = .details
        let view = ItemListView(model: model)
        view.computeLayout()
        view.scheduleRelativeDateRefresh()
        #expect(view.relativeDateTimer == nil)
        let timer = Timer(timeInterval: 60, repeats: false) { _ in }
        view.relativeDateTimer = timer
        view.isHidden = true
        #expect(!timer.isValid && view.relativeDateTimer == nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        #expect(!window.isVisible && !window.isKeyWindow)
        view.isHidden = false
        view.scheduleRelativeDateRefresh()
        #expect(view.relativeDateTimer == nil)
        window.contentView = nil
        window.close()
    }

    @Test func clockUsesVisibleRowsAndStopsWhenDatesOrTheWindowDisappear() throws {
        let scratch = try Scratch()
        let now = Date()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<1000).map { i in
            FileItem(
                url: scratch.url.appendingPathComponent(String(format: "%04d", i)), name: String(format: "%04d", i), isDirectory: false,
                modificationDate: now.addingTimeInterval(i < 900 ? -86400 : -5))
        }
        model.props.mode = .details
        let list = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 120))
        scroll.documentView = list
        let window = VisibleDateFixtureWindow(contentRect: scroll.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { list.stopRelativeDateRefresh(); window.close() }
        list.computeLayout()
        list.scheduleRelativeDateRefresh(now: now)
        let timer = try #require(list.relativeDateTimer)
        let midnight = try #require(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)))
        #expect(timer.fireDate == midnight)  // Recent offscreen rows must not cause minute wakeups.
        Settings.shared.dateStyle = .absolute
        #expect(list.relativeDateTimer == nil && !timer.isValid)
        Settings.shared.dateStyle = .relative
        model.props.setRoles([.size], for: .details)
        list.computeLayout(); list.scheduleRelativeDateRefresh(now: now)
        #expect(list.relativeDateTimer == nil)
        model.props.setRoles([.modificationTime], for: .details)
        list.computeLayout(); list.scheduleRelativeDateRefresh(now: now)
        #expect(list.relativeDateTimer != nil)
        window.fixtureVisible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(list.relativeDateTimer == nil)
        window.fixtureVisible = true
        list.scheduleRelativeDateRefresh(now: now)
        #expect(list.relativeDateTimer != nil)
        window.contentView = nil
        #expect(list.relativeDateTimer == nil)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func dateColumnsRenderInBothAppearancesWithoutPresenting() throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous; Theme.lookChanged() }
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let now = Date()
        let samples: [(String, Double)] = [
            ("1 Just saved.txt", 5), ("2 Previous minute.txt", 90), ("3 Recent changes.txt", 59 * 60),
            ("4 Earlier changes.txt", 7200), ("5 Yesterday.txt", 86400), ("6 Earlier this week.txt", 3 * 86400),
            ("7 Older document.txt", 30 * 86400),
        ]
        model.searchResults = samples.map { name, age in
            FileItem(
                url: scratch.url.appendingPathComponent(name), name: name, isDirectory: false, size: 1234,
                modificationDate: now.addingTimeInterval(-age))
        }
        model.props.mode = .details
        let list = ItemListView(model: model)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 310))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 284))
        scroll.documentView = list; root.addSubview(scroll)
        let header = DetailsHeaderView(frame: CGRect(x: 0, y: 284, width: 800, height: 26))
        header.list = list; root.addSubview(header)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        for appearance in [AppearanceChoice.light, .dark] {
            Settings.shared.appearance = appearance; app.appearance = Theme.appearance; Theme.lookChanged()
            window.appearance = Theme.appearance
            list.computeLayout()
            #expect(list.columnWidths[.modificationTime] == 200)
            #expect(!window.isVisible && !window.isKeyWindow && list.relativeDateTimer == nil)
            if let folder = ProcessInfo.processInfo.environment["PORPOISE_DATE_CAPTURES"] {
                let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
                let directory = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("modified-dates-\(appearance.rawValue).png"))
            }
        }
    }
}

/// Reports a visible viewport to exercise scheduling, without ever ordering a native window.
@MainActor private final class VisibleDateFixtureWindow: NSWindow {
    var fixtureVisible = true
    override var occlusionState: NSWindow.OcclusionState { fixtureVisible ? [.visible] : [] }
}
