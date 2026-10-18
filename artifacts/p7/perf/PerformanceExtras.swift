import AppKit
import PorpoiseCore
import PorpoiseServices
import Testing

@testable import Porpoise

@Suite(.serialized) @MainActor struct PerformanceExtras {
    @Test func notificationsAndTags() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/p7/perf")
        let empty = root.appendingPathComponent("fixture-empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        for n in [10000, 100000] {
            let container = ViewContainer(url: empty)
            container.model.searchResults = (0..<n).map {
                FileItem(
                    url: empty.appendingPathComponent("file-\($0).txt"), name: "file-\($0).txt", isDirectory: false, contentType: "public.plain-text")
            }
            var p = container.model.props; p.mode = .icons; container.model.props = p
            var changes = 0
            let prior = container.model.onChange
            container.model.onChange = {
                changes += 1; prior?()
            }
            PerformanceSweep().measure("unrelated_setting_icons_\(n)", count: 3) {
                NotificationCenter.default.post(name: Settings.changed, object: "terminalFollowsDirectory")
            }
            print("PERF unrelated_setting_icons_\(n) rebuilds=\(changes) notifications=3")
        }
        let big =
            ProcessInfo.processInfo.environment["PERFAPP_FIXTURE"].map { URL(fileURLWithPath: $0).appendingPathComponent("big") }
            ?? root.appendingPathComponent("fixture/big")
        for n in [10000, 100000] {
            let urls = (0..<n).map { big.appendingPathComponent(String(format: "file-%06d.txt", $0)) }
            PerformanceSweep().measure("tag_menu_\(n)", count: 3) { _ = TagDotsView.view(for: urls) { _ in } }
        }
    }
    @Test func normalDirectoryDetails() {
        _ = NSApplication.shared
        Settings.shared.detailsExpandableFolders = true
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/p7/perf/fixture-empty")
        for n in [10000, 100000] {
            let model = DirectoryModel(location: root, prefetchFolders: false)
            let items = (0..<n).map {
                FileItem(
                    url: root.appendingPathComponent("normal-\($0).txt"), name: "normal-\($0).txt", isDirectory: false,
                    contentType: "public.plain-text")
            }
            _ = model.applyEdit(ListingEdit(folder: root, added: items))
            var p = model.props; p.mode = .details; model.props = p
            let view = ItemListView(model: model)
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1100, height: 700)); scroll.documentView = view
            PerformanceSweep().measure("normal_details_layout_\(n)") { view.computeLayout() }
            print("PERF normal_details_\(n) rows=\(model.rows.count) treeLines=\(view.treeLines.count) searching=\(model.isSearching)")
        }
    }

}
