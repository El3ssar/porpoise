import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudQuotaTests {
    @Test func spaceUsageProtectsUnsignedByteCounts() throws {
        func decode(_ json: String) throws -> DropboxSpaceUsage { try JSONDecoder().decode(DropboxSpaceUsage.self, from: Data(json.utf8)) }
        let overflow = try decode(#"{"used":18446744073709551615,"allocation":{".tag":"individual","allocated":18446744073709551615}}"#)
        #expect(overflow.used == nil && overflow.total == nil)
        let zero = try decode(#"{"used":0,"allocation":{".tag":"individual","allocated":0}}"#)
        #expect(zero.used == 0 && zero.total == 0)
        #expect(throws: (any Error).self) { try decode(#"{"used":-1,"allocation":{".tag":"individual","allocated":10}}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"used":1,"allocation":{".tag":"team","allocated":10}}"#) }
    }

    @Test(.timeLimit(.minutes(5))) @MainActor func sharedQuotaCadenceStartsRepeatsAndStops() async throws {
        #expect(CloudAccountRefreshPolicy.interval == 45)
        var calls = 0
        var refresh: CloudQuotaRefresh!
        // Wait for the observed refresh, rather than measuring main-actor scheduling under a full parallel suite.
        try await awaitCallback { continuation in
            refresh = CloudQuotaRefresh(interval: 0.01) {
                calls += 1
                if calls == 3 { continuation.resume() }
            }
            refresh.setActive(false); #expect(calls == 0)
            refresh.setActive(true); #expect(calls == 1)
        }
        #expect(calls >= 3)
        refresh.setActive(false)
        let stopped = calls
        try await Task.sleep(for: .milliseconds(40))
        #expect(calls == stopped)
        refresh.setActive(true); #expect(calls == stopped + 1)
        refresh.setActive(false)
    }
}
