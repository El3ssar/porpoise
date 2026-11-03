import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Opt-in diagnostics. Builds the exact loaded-row anchor lookup used when an
/// update restores the visible item; no window is created or ordered.
@MainActor @Suite(.isolatedSettings) struct ViewGeometryPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_VIEW_GEOMETRY_BENCHMARK"] == "1"))
    func loadedGeometryAndAnchorLookup() async throws {
        _ = NSApplication.shared
        Settings.shared.folderSizeMode = .none
        Settings.shared.showGitStatus = false
        let scratch = try Scratch("view-geometry-benchmark")
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<100_000).map {
            FileItem(url: scratch.url.appendingPathComponent("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false)
        }
        let view = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        scroll.documentView = view
        model.props.mode = .details
        view.computeLayout()
        let key = view.key(ofRow: 75_000)
        let expected = model.rows[75_000].item.url
        var metrics: [String: Double] = [:]
        func measure(_ key: String, _ body: () -> Void) {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            metrics[key] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        measure("cold_anchor_ms") { #expect(view.row(forKey: key) == 75_000) }
        measure("resize_and_anchor_20_ms") {
            for _ in 0..<20 {
                scroll.frame.size.width += 1
                view.computeLayout()
                let index = view.row(forKey: key)
                #expect(index == 75_000)
                #expect(index.map { model.rows[$0].item.url } == expected)
            }
        }
        measure("warm_anchor_100_ms") {
            for _ in 0..<100 { #expect(view.row(forKey: key) == 75_000) }
        }
        #expect(view.window == nil && scroll.documentView === view)
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("VIEW_GEOMETRY_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }
}
