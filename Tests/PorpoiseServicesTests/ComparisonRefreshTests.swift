import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor struct ComparisonRefreshTests {
    @Test func rapidNavigationCoalescesToTheFinalPair() async throws {
        let refresh = ComparisonRefresh(), left = URL(fileURLWithPath: "/left"), right = URL(fileURLWithPath: "/right")
        var started: [ComparisonRefresh.Request] = []
        refresh.onStart = { started.append($0) }
        let old = refresh.schedule(left: left, right: right, delay: 0.03)
        let latest = refresh.schedule(left: left.appendingPathComponent("child"), right: right.appendingPathComponent("child"), delay: 0.03)
        #expect(old.cancellation.isCancelled); #expect(!refresh.accepts(old)); #expect(refresh.accepts(latest))
        #expect(await eventually(5) { started.count == 1 })
        #expect(started.first?.left == latest.left); #expect(started.first?.right == latest.right)
    }
    @Test func newerScanRejectsOutOfOrderResultsAndStopCancelsPendingNavigation() async throws {
        let refresh = ComparisonRefresh(), root = URL(fileURLWithPath: "/pair")
        var starts = 0; refresh.onStart = { _ in starts += 1 }
        let slow = refresh.schedule(left: root, right: root, delay: 0)
        let fresh = refresh.schedule(left: root.appendingPathComponent("new"), right: root, delay: 0)
        #expect(starts == 2); #expect(!refresh.accepts(slow)); #expect(refresh.accepts(fresh))
        #expect(slow.cancellation.isCancelled)
        let pending = refresh.schedule(left: root, right: root, delay: 0.03)
        refresh.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(starts == 2); #expect(refresh.current == nil)
        #expect(pending.cancellation.isCancelled); #expect(!refresh.accepts(pending)); #expect(!refresh.accepts(fresh))
        let resumed = refresh.schedule(left: root, right: root, delay: 0)
        #expect(starts == 3); #expect(refresh.accepts(resumed))
    }
}
