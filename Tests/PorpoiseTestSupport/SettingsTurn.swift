import Foundation

/// `Settings.store` is one store for the whole process, and on CI every test target runs in that one process: tests
/// that swap it (Services' `.isolatedSettings`, the app's) take turns, or one test's settings land in another's store.
public actor SettingsTurn {
    public static let shared = SettingsTurn()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    public func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// UserDefaults whose values live in memory only. Every typed accessor (`bool(forKey:)`, `set(_:forKey:)` for a
/// Double…) goes through these three, so the app's code reads and writes it exactly as it does the real store.
public final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    public init() { super.init(suiteName: nil)! }

    override public func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override public func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override public func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
}
