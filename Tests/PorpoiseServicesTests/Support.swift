import Foundation
import Testing

@testable import PorpoiseServices

/// `Settings.store` is one store for the whole process, so tests that read or write settings take turns: each runs
/// with a fresh, empty store kept in memory (nothing is written to disk, nothing is left behind). Put
/// `.isolatedSettings` on such a test or suite.
struct IsolatedSettings: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }  // the suite itself: each test gets its own
        await SettingsTurn.shared.acquire()
        let previous = Settings.store
        Settings.store = MemoryDefaults()
        Settings.isTesting = true
        var failure: Error?
        do { try await function() } catch { failure = error }
        Settings.store = previous
        await SettingsTurn.shared.release()
        if let failure { throw failure }
    }
}

/// UserDefaults whose values live in memory only. Every typed accessor (`bool(forKey:)`, `set(_:forKey:)` for a
/// Double…) goes through these three, so the app's code reads and writes it exactly as it does the real store.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
}

extension Trait where Self == IsolatedSettings {
    static var isolatedSettings: Self { IsolatedSettings() }
}

/// One test at a time with the settings store.
private actor SettingsTurn {
    static let shared = SettingsTurn()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// Waits up to `timeout` seconds for `condition`, letting the main queue run (models finish their loads there).
@MainActor
func eventually(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Runs a command line tool and fails the test if it fails.
@discardableResult
func run(_ tool: String, _ args: [String], in dir: URL? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.currentDirectoryURL = dir
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(args.joined(separator: " ")) failed"])
    }
    return String(decoding: data, as: UTF8.self)
}
