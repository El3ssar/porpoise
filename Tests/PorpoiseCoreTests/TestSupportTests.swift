import Foundation
import PorpoiseTestSupport
import Testing

/// The shared test helpers hold up themselves: tests that lean on them fail for their own reasons only.
struct TestSupportTests {
    /// What threads record at once is all there afterwards (B16: a bare `var` in an `@unchecked Sendable` class lost
    /// some of it, and reading it meanwhile was a data race).
    @Test func lockedKeepsEveryChangeFromManyThreads() {
        let seen = Locked(Set<Int>())
        DispatchQueue.concurrentPerform(iterations: 2000) { n in
            seen.change { $0.insert(n) }
            _ = seen.value.count
        }
        #expect(seen.value == Set(0..<2000))
    }

    /// Tests that need defaults use these instead of named suites on disk, which piled up in ~/Library/Preferences:
    /// they read back what was set, through the typed accessors the app uses, and each starts empty.
    @Test func memoryDefaultsActLikeDefaultsAndLeaveNothingBehind() {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: "flag")
        defaults.set(3, forKey: "count")
        defaults.set(Data("x".utf8), forKey: "data")
        defaults.set(["a": 1], forKey: "dictionary")
        #expect(defaults.bool(forKey: "flag") && defaults.integer(forKey: "count") == 3)
        #expect(defaults.data(forKey: "data") == Data("x".utf8))
        #expect(defaults.dictionary(forKey: "dictionary")?["a"] as? Int == 1)
        defaults.removeObject(forKey: "flag")
        #expect(defaults.object(forKey: "flag") == nil)
        #expect(MemoryDefaults().object(forKey: "count") == nil)
    }
}
