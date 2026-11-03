import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Opt-in release measurements, using the real model and layout without ordering a window on screen.
/// No wall-clock assertions: compare alternating baseline/candidate processes on the same host.
@MainActor @Suite(.isolatedSettings) struct BrowsingPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_BROWSING_BENCHMARK"] == "1"))
    func offscreenBrowsing() throws {
        _ = NSApplication.shared
        let scratch = try Scratch("browsing-performance")
        Settings.shared.folderSizeMode = .none
        Settings.shared.showGitStatus = false
        let count = Int(ProcessInfo.processInfo.environment["PORPOISE_BROWSING_FILES"] ?? "100000") ?? 100000
        try #require((100...100000).contains(count))
        for longNames in [false, true] {
            let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
            let items = (0..<count).map { index in
                let name = longNames ? "project-\(index)-the-complete-annual-research-report-and-appendices.txt" : "file-\(index).txt"
                return FileItem(url: scratch.url.appendingPathComponent(name), name: name, isDirectory: false)
            }
            var metrics: [String: Double] = [:]
            func measure(_ name: String, _ body: () -> Void) {
                let before = ProcessInfo.processInfo.systemUptime
                body()
                metrics[name] = (ProcessInfo.processInfo.systemUptime - before) * 1000
            }
            measure("model_ms") { model.searchResults = items }
            let view = ItemListView(model: model)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
            scroll.documentView = view
            for mode in [ViewMode.icons, .details, .compact] {
                model.props.mode = mode
                measure("\(mode.rawValue)_initial_ms") { view.computeLayout() }
                measure("\(mode.rawValue)_resize_20_ms") {
                    for _ in 0..<20 {
                        scroll.frame.size.width += 1
                        view.computeLayout()
                    }
                }
                try #require(view.frames.count == count)
                let visible = view.candidateIndexes(in: NSRect(x: 0, y: 0, width: 1000, height: 600))
                #expect(!visible.isEmpty && visible.count < count)
            }
            #expect(view.window == nil)
            let payload: [String: Any] = ["files": count, "longNames": longNames, "metrics": metrics]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print("BROWSING_BENCHMARK \(String(decoding: data, as: UTF8.self))")
        }
    }
}
