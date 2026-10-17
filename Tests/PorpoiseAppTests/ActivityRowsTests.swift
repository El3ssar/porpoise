import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@Suite(.serialized) struct ActivityRowsTests {
    @Test(.isolatedSettings) @MainActor func bothTransferRowsRenderTheSharedDetailAndAccessibility() {
        _ = NSApplication.shared
        let a = Activity(
            kind: .copy, sources: [URL(fileURLWithPath: "/fixture/report.txt")],
            destination: URL(fileURLWithPath: "/fixture/target"), job: nil)
        let row = ActivityRowView(window: nil, alternate: false), compact = TransferPopoverRow(frame: .zero)
        for state: Activity.State in [.queued, .running, .paused, .waiting, .completed, .failed, .cancelled, .interrupted] {
            a.state = state
            row.update(a); compact.update(a)
            let expected = ActivityPresentation(a)
            for view: NSView in [row, compact] {
                let text = view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
                #expect(text.contains(expected.detailLine))
                #expect(view.accessibilityLabel() == expected.title + ". " + expected.detailLine)
            }
        }
        let trash = Activity(kind: .trash, sources: a.sources, destination: nil, job: nil)
        trash.state = .completed
        row.update(trash)
        #expect(row.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Done" })
        row.frame = CGRect(x: 0, y: 0, width: 430, height: 52)
        row.layoutSubtreeIfNeeded()
        #expect(row.subviews.allSatisfy { $0.frame.size.width.isFinite && $0.frame.size.height.isFinite })
    }
}
