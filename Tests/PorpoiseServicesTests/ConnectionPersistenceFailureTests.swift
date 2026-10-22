import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite struct ConnectionPersistenceFailureTests {
    private let profile = ConnectionProfile(name: "Work", kind: .sftp, host: "work.example.com")

    @Test @MainActor func failedWriteKeepsDurableStateAndPostsNothingThenRetries() throws {
        let scratch = try Scratch("connection-write-failure")
        let file = scratch.path("connections.json")
        let store = ConnectionProfiles(storeURL: file)
        try store.save(profile).get()
        let original = try Data(contentsOf: file)
        let notifications = ConnectionMonitorTests.Counter()
        let observer = NotificationCenter.default.addObserver(forName: ConnectionProfiles.changed, object: store, queue: nil) { _ in
            notifications.add()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // A directory at the target fails even when running with privileges; no timing or permission assumptions.
        try FileManager.default.moveItem(at: file, to: scratch.path("original.json"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var edited = profile
        edited.name = "Changed"
        #expect(throws: (any Error).self) { try store.save(edited).get() }
        #expect(store.profiles == [profile])
        #expect(notifications.value == 0)
        #expect(try Data(contentsOf: scratch.path("original.json")) == original)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: scratch.path("original.json"), to: file)
        #expect(ConnectionProfiles(storeURL: file).profiles == [profile])
        try store.save(edited).get()
        #expect(notifications.value == 1)
        #expect(ConnectionProfiles(storeURL: file).profiles == [edited])
    }

    @Test func concurrentEditsKeepEveryCommittedProfile() throws {
        let scratch = try Scratch("connection-concurrent-writes")
        let file = scratch.path("connections.json")
        let store = ConnectionProfiles(storeURL: file)
        let failures = ConnectionMonitorTests.Counter()
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            let p = ConnectionProfile(name: "Server \(i)", kind: .sftp, host: "host-\(i).example.com")
            if case .failure = store.save(p) { failures.add() }
        }
        #expect(failures.value == 0)
        #expect(store.profiles.count == 20)
        #expect(ConnectionProfiles(storeURL: file).profiles == store.profiles)
        #expect(Set(store.profiles.map(\.name)).count == 20)
    }

    @Test func nonDirectoryParentDoesNotInventASavedConnection() throws {
        let scratch = try Scratch("connection-parent-failure")
        let parent = try scratch.file("parent", "not a directory")
        let store = ConnectionProfiles(storeURL: parent.appendingPathComponent("connections.json"))
        #expect(throws: (any Error).self) { try store.save(profile).get() }
        #expect(store.profiles.isEmpty)
        #expect(scratch.read("parent") == "not a directory")
    }

    private final class FailingBackup: FileManager, @unchecked Sendable {
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    @Test func failedBackupNeverOverwritesTheDamagedOriginal() throws {
        let scratch = try Scratch("connection-backup-failure")
        let file = try scratch.file("connections.json", "{ damaged")
        let store = ConnectionProfiles(storeURL: file, fileManager: FailingBackup())
        #expect(store.profiles.isEmpty)
        #expect(throws: (any Error).self) { try store.save(profile).get() }
        #expect(store.profiles.isEmpty)
        #expect(scratch.read("connections.json") == "{ damaged")
        #expect(!FileManager.default.fileExists(atPath: scratch.path("connections.unreadable.json").path))
        // A later healthy store can recover the same file: the first failed read didn't consume it.
        let retry = ConnectionProfiles(storeURL: file)
        try retry.save(profile).get()
        #expect(scratch.read("connections.unreadable.json") == "{ damaged")
        #expect(ConnectionProfiles(storeURL: file).profiles == [profile])
    }

    @Test func priorBackupsAndNewerSchemasArePreserved() throws {
        let scratch = try Scratch("connection-backup-history")
        let newer = "{\"version\":999,\"profiles\":[]}"
        let file = try scratch.file("connections.json", newer)
        try scratch.file("connections.unreadable.json", "older damage")
        let store = ConnectionProfiles(storeURL: file)
        try store.save(profile).get()
        #expect(scratch.read("connections.unreadable.json") == "older damage")
        let backups = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("connections.unreadable-") }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try String(contentsOf: backup, encoding: .utf8) == newer)
        #expect(ConnectionProfiles(storeURL: file).profiles == [profile])
    }

    @Test func failedRemovalKeepsTheProfileAndItsS3Secret() throws {
        let scratch = try Scratch("connection-remove-failure")
        let file = scratch.path("connections.json")
        let store = ConnectionProfiles(storeURL: file)
        let s3 = MemoryS3Secrets()
        let credentials = ConnectionCredentials.inMemory(s3: s3)
        let p = ConnectionProfile(name: "Backups", kind: .s3, bucket: "backups", accessKeyID: "fixture")
        try store.save(p).get()
        try credentials.saveSecret("fixture-secret", for: p)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.remove(p.id, credentials: credentials).get() }
        #expect(store.profiles == [p])
        #expect(credentials.hasSecret(for: p))
    }
}
