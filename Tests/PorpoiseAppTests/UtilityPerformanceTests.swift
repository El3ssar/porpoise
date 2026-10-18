import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@Suite(.isolatedSettings) struct UtilityPerformanceTests {
    @Test @MainActor func renamePreviewPublishesLatestInputAndStopsOnClose() async throws {
        _ = NSApplication.shared
        let count = ProcessInfo.processInfo.environment["PORPOISE_DISK_BENCHMARK"] == "1" ? 10000 : 200
        let entries = (0..<count).map { BatchRenameEntry(url: URL(fileURLWithPath: "/fixture/item-\($0).txt")) }
        let snapshot = BatchRenameSnapshot(
            entries: entries, existing: ["/fixture": entries.map(\.url.lastPathComponent)], caseSensitive: [:], identities: [:])
        let preset = BatchRenamePreset(name: "", extensionMode: .change("latest"))
        let before = ProcessInfo.processInfo.systemUptime
        let synchronous = BatchRenameService.preview(snapshot, preset: preset)
        let synchronousMS = (ProcessInfo.processInfo.systemUptime - before) * 1000
        let dialog = BatchRenameDialog(entries.map(\.url), snapshot: snapshot) { _ in }
        defer { dialog.testFinish() }
        let start = ProcessInfo.processInfo.systemUptime
        for ext in ["old", "older", "latest"] { dialog.testPreviewExtension(ext) }
        let schedulingMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        #expect(dialog.testPlan == nil && !dialog.testCanApply)
        #expect(await poll { dialog.testPlan != nil })
        #expect(dialog.testPlan?.rows.map(\.proposedName) == synchronous.rows.map(\.proposedName))
        #expect(dialog.testCanApply)
        dialog.testPreviewExtension("closed")
        dialog.testFinish()
        // A callback already queued before close must never re-enable Rename.
        await Task.yield()
        #expect(dialog.testPlan == nil && !dialog.testCanApply)
        print("Rename \(count) rows: synchronous preview \(synchronousMS) ms; 3 input changes scheduled on main \(schedulingMS) ms")
    }

    @Test @MainActor func treemapReusesGeometryUntilBoundsOrItemsChange() throws {
        let view = DiskTreemapView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        view.items = (0..<500).map { ($0, "Item \($0)", Int64($0 + 1)) }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        for _ in 0..<4 { view.cacheDisplay(in: view.bounds, to: bitmap) }
        #expect(view.layoutCount == 1)
        view.frame.size.width += 1
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(view.layoutCount == 2)
        view.items[0].2 += 10
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(view.layoutCount == 3)
    }

    @Test func presentationCancellationStopsCommonAndChangedRows() throws {
        let difference = TextDifference(
            left: String(repeating: "same\n", count: 2000) + "old\n", right: String(repeating: "same\n", count: 2000) + "new\n")
        for inline in [false, true] {
            var checks = 0
            #expect(throws: CancellationError.self) {
                _ = try FileDiffPresentation(
                    difference, inline: inline,
                    checkCancellation: {
                        checks += 1
                        if checks == 4 { throw CancellationError() }
                    })
            }
            #expect(checks == 4)
            let normal = FileDiffPresentation(difference, inline: inline)
            let live = FileDiffPresentation(difference, inline: inline, checkCancellation: {})
            #expect(normal.starts == live.starts && normal.rows.count == live.rows.count)
        }
    }
}
