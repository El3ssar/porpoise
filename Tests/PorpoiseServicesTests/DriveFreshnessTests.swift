import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Drive folders stay fresh in place: a saved listing paints at once, Drive's answer glides in through the view's
/// animation, and offline folders say how old they are.
@MainActor @Suite(.serialized, .isolatedSettings) struct DriveFreshnessTests {
    @Test func driveAnswerAfterTheSavedListingGoesThroughTheViewsAnimation() async throws {
        let server = try FakeDriveServer(latencyMS: 20)
        defer { server.stop() }
        let (client, _, _) = try server.client()
        let provider = DriveProvider(accountID: client.accountID, client: client)
        let root = DriveLocation(accountID: client.accountID).url
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let rows = try await provider.refresh(root)
        let model = DirectoryModel(location: root)
        var animated = 0
        model.onRemoteUpdate = { apply in
            animated += 1
            apply()
        }
        var loaded = 0
        model.onLoaded = { loaded += 1 }
        // First visit: the saved listing paints at once, no animation (nothing was shown before).
        model.reload()
        #expect(model.items == rows && model.isRefreshing && animated == 0)
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRefreshing)
        #expect(!model.isRefreshing && animated == 0)
        let selected = try #require(rows.first { $0.name == "report.txt" }).url
        model.selection = [selected]

        // Changed in the browser: the next look at the folder animates the difference and keeps the selection.
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Drive/metadata.json")
        var changed = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        var files = try #require(changed["files"] as? [[String: Any]])
        files[2]["name"] = "Updated report.txt"
        changed["files"] = files
        var request = URLRequest(url: server.base.appendingPathComponent("__fixture"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: changed)
        _ = try await URLSession.shared.data(for: request)
        loaded = 0
        model.reload()
        #expect(model.isRefreshing && animated == 0)
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRefreshing)
        #expect(animated == 1 && loaded == 2)
        #expect(model.items.contains { $0.name == "Updated report.txt" } && model.selection == [selected])

        // Nothing new: no animation at all.
        model.reload()
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRefreshing)
        #expect(animated == 1)

        // The patched listing is the saved one (as after a change poll): it glides in at once, without waiting.
        provider.invalidate()
        _ = try await provider.refresh(root)
        files[2]["name"] = "Final report.txt"
        changed["files"] = files
        request.httpBody = try JSONSerialization.data(withJSONObject: changed)
        _ = try await URLSession.shared.data(for: request)
        _ = try await provider.refresh(root)
        model.reload()
        #expect(animated == 2 && model.items.contains { $0.name == "Final report.txt" })
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRefreshing)
    }

    @Test func offlineMessageSaysHowOldTheListingIs() throws {
        let backend = DemoCloudBackend()
        _ = backend.connect(.googleDrive, openBrowser: { _ in }, done: { _ in })
        backend.finishSignIn(CloudAccount(id: "a1", email: "daniel@gmail.com", displayName: "Daniel"))
        let accounts = CloudAccounts()
        accounts.backend = backend
        let myDrive = try #require(accounts.url("a1", root: .myDrive))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 15, minute: 30)))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 5)))
        let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 18, minute: 40)))

        #expect(accounts.offlineMessage(for: myDrive, hasListing: false) == "You’re offline. This folder opens when you’re back online.")
        #expect(
            accounts.offlineMessage(for: myDrive, hasListing: true, now: now)
                == "You’re offline. Showing Google Drive as it was when you last opened it.")
        backend.savedDates[myDrive] = morning
        let today = accounts.offlineMessage(for: myDrive, hasListing: true, now: now)
        #expect(today.hasPrefix("You’re offline. Showing Google Drive as it was today at ") && today.hasSuffix("."))
        backend.savedDates[myDrive] = earlier
        #expect(accounts.offlineMessage(for: myDrive, hasListing: true, now: now).contains("as it was yesterday at "))
        #expect(CloudAccounts.when(earlier, now: now.addingTimeInterval(9 * 86400)).hasPrefix("on "))
    }
}
