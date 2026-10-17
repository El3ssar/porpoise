import Foundation
import PorpoiseServices
import PorpoiseTestSupport
import Testing

/// `Settings.store` is one store for the whole process (and on CI every test target runs in that one process), so
/// tests that read or write settings take turns: each runs with a fresh, empty store kept in memory (nothing is written
/// to disk, nothing is left behind). Put `.isolatedSettings` on such a test or suite.
public struct IsolatedSettings: TestTrait, SuiteTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }  // the suite itself: each test gets its own
        await SettingsTurn.shared.acquire()
        let previous = Settings.store
        Settings.store = MemoryDefaults()
        // Stays set afterwards: the process is a test run, and a later test must never write the real ~/Library.
        Settings.isTesting = true
        var failure: Error?
        do { try await function() } catch { failure = error }
        Settings.store = previous
        await SettingsTurn.shared.release()
        if let failure { throw failure }
    }
}

extension Trait where Self == IsolatedSettings {
    public static var isolatedSettings: Self { IsolatedSettings() }
}
