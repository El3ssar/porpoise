import AppKit
import PorpoiseCore
import PorpoiseServices
import SwiftTerm
import Testing

@testable import Porpoise

@Suite(.serialized) @MainActor struct PerformanceSweep {
    func measure(_ name: String, count: Int = 5, _ body: () -> Void) {
        var times: [Double] = []
        for _ in 0..<count {
            let t = CACurrentMediaTime()
            autoreleasepool { body() }
            times.append((CACurrentMediaTime() - t) * 1000)
        }
        times.sort()
        print("PERF \(name) median_ms=\(times[times.count/2]) min_ms=\(times.first!) max_ms=\(times.last!)"); fflush(stdout)
    }
    @Test func sweep() throws {
        _ = NSApplication.shared
        let defaultRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/p7/perf/fixture-" + UUID().uuidString)
        let root = ProcessInfo.processInfo.environment["PERFAPP_FIXTURE"].map { URL(fileURLWithPath: $0) } ?? defaultRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Settings.shared.previewFolders = false
        for n in [10_000, 100_000] {
            let model = DirectoryModel(location: root)
            let items = (0..<n).map { i in
                FileItem(
                    url: root.appendingPathComponent(String(format: "file-%06d.txt", i)), name: String(format: "file-%06d.txt", i),
                    isDirectory: false, size: Int64(i), contentType: "public.plain-text")
            }
            model.searchResults = items
            let view = ItemListView(model: model)
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1100, height: 700))
            scroll.documentView = view
            for mode in [ViewMode.icons, .details, .compact] {
                var props = model.props; props.mode = mode; model.props = props
                measure("layout_\(mode)_\(n)") { view.computeLayout() }
                print(
                    "PERF cache_\(mode)_\(n) textWidths=\(view.textWidthCache.count) frames_bytes=\(view.frames.count * MemoryLayout<CGRect>.stride)")
                measure("candidates_1000_\(mode)_\(n)") {
                    for i in 0..<1000 { _ = view.candidateIndexes(in: CGRect(x: CGFloat(i * 11), y: CGFloat(i * 101), width: 1000, height: 700)) }
                }
                measure("resize_\(mode)_\(n)") {
                    scroll.frame.size.width += 1; view.transitions.resized()
                }
                measure("zoom_\(mode)_\(n)") { view.previewZoom(view.iconSize == 64 ? 65 : 64, commitAfter: nil) }
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 700, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                measure("draw_visible_\(mode)_\(n)", count: 3) {
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    view.draw(CGRect(x: 0, y: 0, width: 1100, height: 700))
                    NSGraphicsContext.restoreGraphicsState()
                }
                if mode == .compact && n == 100_000 {
                    view.textWidthCache = Dictionary(uniqueKeysWithValues: items.map { ($0.name, CGFloat(110)) } + [("x", CGFloat(7))])
                    measure("compact_complete_cache_counterfactual_100000") { view.computeLayout() }
                }
            }
        }
        Settings.shared.previewFolders = true
        let big = root.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for n in [10_000, 100_000] {
            let start = n == 10_000 ? 0 : 10_000
            for i in start..<n {
                FileManager.default.createFile(atPath: big.appendingPathComponent(String(format: "file-%06d.txt", i)).path, contents: Data())
            }
            let folder = FileItem.load(big)!
            measure("folder_preview_cold_\(n)", count: 3) {
                let thumbnails = Thumbnails(); _ = thumbnails.folderPreview(for: folder, size: 64)
            }
            measure("folder_expandability_\(n)", count: 3) { _ = FoldersPanel.Node(big).isExpandable(showHidden: false) }
            measure("folder_tree_load_\(n)", count: 3) { _ = FoldersPanel.Node(big).load(showHidden: false) }
        }
        var appearance = Settings.shared.appearancePreferences
        appearance.shell = .custom; appearance.customShell = "/bin/bash"; appearance.shellArguments = ["--noprofile", "--norc", "-i"]
        Settings.shared.appearancePreferences = appearance
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = TerminalPanel(frame: CGRect(x: 0, y: 0, width: 1000, height: 300))
        window.contentView = terminal
        measure("terminal_start", count: 1) { terminal.follow(root) }
        measure("terminal_state_1000") { for _ in 0..<1000 { _ = terminal.hasRunningProgram; _ = terminal.currentDirectory } }
        measure("terminal_feed_10000_lines", count: 3) {
            terminal.terminalView.feed(text: String(repeating: "abcdefghijklmnopqrstuvwxyz 0123456789\r\n", count: 10000))
        }
        terminal.terminate()
        let model = DirectoryModel(location: root, prefetchFolders: false)
        let view = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600)); scroll.documentView = view
        window.contentView = scroll
        let reduce = Animator.reducesMotion; Animator.reducesMotion = { false }
        for n in [100, 3000, 10000] {
            model.searchResults = (0..<n).map {
                FileItem(
                    url: root.appendingPathComponent("split-\($0).txt"), name: "split-\($0).txt", isDirectory: false, contentType: "public.plain-text"
                )
            }
            var p = model.props; p.mode = .icons; model.props = p; view.computeLayout()
            var pictures: [String: CGImage]?
            measure("split_snapshot_\(n)", count: 3) { pictures = view.transitions.flightPictures() }
            print(
                "PERF split_snapshot_\(n) pictures=\(pictures?.count ?? 0) pixel_bytes=\(pictures?.values.reduce(0) { $0 + $1.bytesPerRow * $1.height } ?? 0)"
            )
        }
        Animator.reducesMotion = reduce; window.close()
        print("PERF pid=\(ProcessInfo.processInfo.processIdentifier)")
    }
}
