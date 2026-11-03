import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Real directory enumeration through the browser's actual navigation and mode actions.
/// Unordered window; readiness includes visible offscreen drawing, not compositor presentation.
@MainActor @Suite(.isolatedSettings) struct NavigationPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_NAVIGATION_BENCHMARK"] == "1"))
    func realFolderRoundTrip() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch("navigation-benchmark")
        let root = ProcessInfo.processInfo.environment["PORPOISE_NAVIGATION_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? scratch.url
        let directory = root.appendingPathComponent("large", isDirectory: true)
        let child = directory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: child.appendingPathComponent("child.txt"))
        let count = Int(ProcessInfo.processInfo.environment["PORPOISE_NAVIGATION_FILES"] ?? "100000") ?? 100000
        try #require((100...100000).contains(count))
        try await Task.detached {
            for index in 0..<count {
                let url = directory.appendingPathComponent("file-\(index).txt")
                if !FileManager.default.fileExists(atPath: url.path), !FileManager.default.createFile(atPath: url.path, contents: Data()) {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }.value
        Settings.shared.folderSizeMode = .none
        Settings.shared.showGitStatus = false
        var style = ViewProperties()
        style.mode = .details
        style.previews = false
        ViewStyleStore().common = style
        let pane = ViewContainer(url: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        defer { window.close() }
        pane.layoutSubtreeIfNeeded()
        try #require(await eventually { !pane.model.isLoading })
        var metrics: [String: Double] = [:]
        var phase = "initial"
        func timedCallback(_ suffix: String, _ original: (() -> Void)?) -> () -> Void {
            {
                let start = ProcessInfo.processInfo.systemUptime
                original?()
                let key = phase + suffix
                metrics[key] = max(metrics[key] ?? 0, (ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        pane.model.onChange = timedCallback("_change_callback_max_ms", pane.model.onChange)
        pane.model.onLoaded = timedCallback("_loaded_callback_max_ms", pane.model.onLoaded)
        pane.model.onPropsChanged = timedCallback("_props_callback_max_ms", pane.model.onPropsChanged)
        func paint() throws {
            pane.layoutSubtreeIfNeeded()
            let rect = pane.list.visibleRect.intersection(pane.list.bounds)
            try #require(!rect.isEmpty && rect.width.isFinite && rect.height.isFinite && rect.width <= 1100 && rect.height <= 700)
            let bitmap = try #require(pane.list.bitmapImageRepForCachingDisplay(in: rect))
            pane.list.cacheDisplay(in: rect, to: bitmap)
        }
        func action(_ name: String, count: Int, _ body: () -> Void) async throws {
            phase = name
            let start = ProcessInfo.processInfo.systemUptime
            body()
            metrics[name + "_call_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == count && pane.list.frames.count == count })
            try paint()
            metrics[name + "_ready_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        try await action("open", count: count + 1) { pane.setURL(directory) }
        let current = directory.appendingPathComponent("file-500.txt")
        pane.model.currentURL = current
        pane.list.scrollToItem(try #require(pane.model.index(of: current)))
        try await action("enter_child", count: 1) { pane.setURL(child) }
        try await action("back", count: count + 1) { pane.goBack() }
        #expect(pane.model.currentURL == child)
        try await action("sort_size", count: count + 1) { pane.model.props.sortRole = .size }
        try await action("sort_descending", count: count + 1) { pane.model.props.sortOrder = .descending }
        for mode in [ViewMode.icons, .details, .compact, .columns, .details] {
            try await action("mode_" + mode.rawValue, count: count + 1) { pane.setMode(mode) }
        }
        #expect(!window.isVisible && !window.isKeyWindow)
        let data = try JSONSerialization.data(withJSONObject: ["files": count, "metrics": metrics], options: [.sortedKeys])
        print("NAVIGATION_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }
}
