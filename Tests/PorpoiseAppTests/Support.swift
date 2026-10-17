import Foundation
import PorpoiseServices
import PorpoiseTestSupport
import Testing

/// The app's tests with settings take the same turns as Services' (`SettingsTurn`): on CI all targets share the
/// process, and a Services test swapping `Settings.store` meanwhile would lose a pane's saved zoom. Each test runs
/// with a fresh, empty store kept in memory.
struct IsolatedSettings: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }  // the suite itself: each test gets its own
        await SettingsTurn.shared.acquire()
        let previous = Settings.store, previousTesting = Settings.isTesting
        Settings.store = MemoryDefaults()
        Settings.isTesting = true
        var failure: Error?
        do { try await function() } catch { failure = error }
        Settings.store = previous
        Settings.isTesting = previousTesting
        await SettingsTurn.shared.release()
        if let failure { throw failure }
    }
}

extension Trait where Self == IsolatedSettings {
    static var isolatedSettings: Self { IsolatedSettings() }
}
