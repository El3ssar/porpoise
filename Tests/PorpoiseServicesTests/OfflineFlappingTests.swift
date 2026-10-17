import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// A network that comes and goes many times a second shows one offline state and one recovery, never a flicker.
@MainActor @Suite(.serialized, .isolatedSettings) struct OfflineFlappingTests {
    @Test func theStateWaitsAndNeverSwitchesTwiceInAFewSeconds() {
        let t0 = Date()
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        var gate = OfflineHysteresis()
        // One failure: not yet; still failing 1.5 s later: offline.
        #expect(!gate.record(reached: false, at: at(0)) && !gate.update(at: at(1)))
        #expect(gate.nextCheck(after: at(1)) == at(1.5))
        #expect(gate.update(at: at(1.5)) && gate.isOffline)
        // Back: only after a request got through and nothing failed for a moment, and not within 3 s of going offline.
        #expect(!gate.record(reached: true, at: at(2)) && gate.nextCheck(after: at(2)) == at(4.5))
        #expect(!gate.update(at: at(3)) && gate.update(at: at(4.5)) && !gate.isOffline)
        // Two failures in a row: offline at once (once the last switch is old enough).
        #expect(!gate.record(reached: false, at: at(8)) && gate.record(reached: false, at: at(8.1)) && gate.isOffline)
        #expect(gate.nextCheck(after: at(9)) == nil)

        // Every other request failing never adds up to being offline.
        var alternating = OfflineHysteresis()
        for n in 0..<200 { _ = alternating.record(reached: n % 2 == 1, at: at(20 + Double(n) * 0.05)) }
        #expect(!alternating.isOffline)
        // Mostly down, up for moments, every 50 ms for 10 s, then steady: one switch each way.
        var flapping = OfflineHysteresis(), switches = 0
        for n in 0..<200 { if flapping.record(reached: n % 3 == 2, at: at(20 + Double(n) * 0.05)) { switches += 1 } }
        #expect(switches == 1 && flapping.isOffline)
        for n in 0..<40 { if flapping.record(reached: true, at: at(30 + Double(n) * 0.1)) { switches += 1 } }
        #expect(switches == 2 && !flapping.isOffline)
    }

    @Test func aFlappingServerShowsOfflineOnceAndRecoversOnce() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Drive/ui-demo.json")
        let server = try FakeDriveServer(fixture: fixture), scratch = try Scratch()
        defer { server.stop() }
        let defaults = MemoryDefaults()
        let store = DriveAccountStore(
            defaults: defaults, credentials: MemoryDriveCredentials(), configuration: server.config,
            baseURL: server.base.appendingPathComponent("drive/v3/"))
        let backend = DriveCloudBackend(store: store, avatarFolder: scratch.url.appendingPathComponent("avatars"))
        let browser: (URL) -> Void = { url in Task { _ = try? await URLSession.shared.data(from: url) } }
        let connected = await withCheckedContinuation { c in _ = backend.connect(.googleDrive, openBrowser: browser) { c.resume(returning: $0) } }
        guard case .success(let account) = connected, let id = UUID(uuidString: account.id), let client = store.client(for: id) else {
            Issue.record("sign-in failed")
            return
        }
        defer { RemoteFS.unregisterDrive(accountID: id) }
        var shown: [CloudAccount.Status] = []
        backend.onChange = {
            let status = backend.accounts.first { $0.id == account.id }?.status ?? .ok
            if status != shown.last ?? .ok { shown.append(status) }
        }
        let flap = DriveMutationTests()
        // Down for 300 ms, up for 100 ms, over and over for about 3 s, reading folders all the while.
        for n in 0..<30 {
            try await flap.control(server, ["offline": n % 4 != 3])
            _ = try? await client.list(DriveLocation(accountID: id))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await flap.control(server, ["offline": false])
        for _ in 0..<50 where shown.last != .ok {
            _ = try? await client.list(DriveLocation(accountID: id))
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(shown == [.offline, .ok])
    }
}
