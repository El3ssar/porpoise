import Foundation
import Testing

@testable import PorpoiseServices

struct SyncNotificationTests {
    @Test func quietPayloadsMatchReviewActionsAndPairGrouping() throws {
        let pair = SavedSync(name: "Website", left: URL(fileURLWithPath: "/Home/Projects"), right: URL(string: "sftp://nas.local/Backup")!)
        let conflict = SyncNotificationPayload(pair: pair, event: .conflicts(2))
        let failed = SyncNotificationPayload(pair: pair, event: .failure(reason: "server.local is full.", waiting: 18))
        let paused = SyncNotificationPayload(pair: pair, event: .deletionReview(count: 340, destination: "Backup"))
        #expect(conflict.title == pair.description + " needs you")
        #expect(conflict.body == "2 files changed on both sides.")
        #expect(failed.title == "Couldn’t sync Website")
        #expect(failed.body == "server.local is full. 18 items are waiting.")
        #expect(paused.title == "Sync paused")
        #expect(paused.body == "340 items would be moved to the Trash in Backup.")
        #expect([conflict.action, failed.action, paused.action] == ["Review", "Show", "Review"])
        for payload in [conflict, failed, paused] {
            #expect(payload.threadIdentifier == pair.id.uuidString)
            #expect(payload.pairID == pair.id)
            #expect(try JSONDecoder().decode(SyncNotificationPayload.self, from: JSONEncoder().encode(payload)) == payload)
        }
        #expect(failed.categoryIdentifier == "PORPOISE_SYNC_SHOW")
        #expect(conflict.categoryIdentifier == paused.categoryIdentifier)
    }
}
