import Foundation
import Testing

@testable import PorpoiseServices

struct GitDeveloperDirectoryCacheTests {
    @Test func timeoutIsNotCachedAndDiscoveryKeepsTheCallersDeadline() throws {
        let cache = GitCommand.DeveloperDirectoryCache()
        var discoveries = 0
        #expect(throws: GitCommand.Failure.budget) {
            try cache.resolve(deadline: 42, now: { 1 }) { deadline in
                discoveries += 1
                #expect(deadline == 42)
                throw GitCommand.Failure.budget
            }
        }
        let directory = try cache.resolve(deadline: 84, now: { 2 }) { deadline in
            discoveries += 1
            #expect(deadline == 84)
            return "/validated/developer"
        }
        let cached = try cache.resolve(deadline: 85, now: { 3 }) { _ in
            discoveries += 1
            throw GitCommand.Failure.unavailable
        }
        #expect(directory == "/validated/developer" && cached == directory)
        #expect(discoveries == 2)
    }

    @Test func expiredBudgetsNeverProbeOrReturnCachedValues() throws {
        let cache = GitCommand.DeveloperDirectoryCache()
        var discoveries = 0
        #expect(throws: GitCommand.Failure.budget) {
            try cache.resolve(deadline: 10, now: { 10 }) { _ in
                discoveries += 1
                return "/must/not/be/discovered"
            }
        }
        #expect(discoveries == 0)
        _ = try cache.resolve(deadline: 20, now: { 10 }) { _ in
            discoveries += 1
            return "/validated/developer"
        }
        #expect(throws: GitCommand.Failure.budget) {
            try cache.resolve(deadline: 20, now: { 21 }) { _ in
                discoveries += 1
                return "/must/not/be/discovered"
            }
        }
        #expect(discoveries == 1)
    }

    @Test func discoveryFailureAndOverBudgetCompletionDoNotPoisonLaterCalls() throws {
        let cache = GitCommand.DeveloperDirectoryCache()
        for failure in [GitCommand.Failure.unavailable, .command] {
            #expect(throws: failure) {
                try cache.resolve(deadline: 20, now: { 1 }) { _ in throw failure }
            }
        }
        var clock: TimeInterval = 1
        #expect(throws: GitCommand.Failure.budget) {
            try cache.resolve(deadline: 20, now: { clock }) { deadline in
                #expect(deadline == 20)
                clock = 21
                return "/too/late"
            }
        }
        let directory = try cache.resolve(deadline: 30, now: { 22 }) { _ in "/validated/developer" }
        #expect(directory == "/validated/developer")
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [GitCommand.Failure] = []
        private var directories: [String] = []
        func add(_ result: Result<String, any Error>) {
            lock.withLock {
                switch result {
                case .success(let directory): directories.append(directory)
                case .failure(let failure): failures.append((failure as? GitCommand.Failure) ?? .command)
                }
            }
        }
        var snapshot: (failures: [GitCommand.Failure], directories: [String]) { lock.withLock { (failures, directories) } }
    }

    @Test func blockedDiscoveryDoesNotHoldTheCacheLockOrEraseConcurrentSuccess() throws {
        let cache = GitCommand.DeveloperDirectoryCache(), outcomes = Outcomes()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let failed = DispatchSemaphore(value: 0), succeeded = DispatchSemaphore(value: 0)
        defer { release.signal() }
        // Dedicated threads avoid occupying the test runner's cooperative pool while waiting at a test boundary.
        Thread {
            outcomes.add(
                Result {
                    try cache.resolve(deadline: 42, now: { 1 }) { deadline in
                        #expect(deadline == 42)
                        entered.signal()
                        guard release.wait(timeout: .now() + 30) == .success else { throw GitCommand.Failure.command }
                        throw GitCommand.Failure.budget
                    }
                })
            failed.signal()
        }.start()
        try #require(entered.wait(timeout: .now() + 10) == .success)
        Thread {
            outcomes.add(
                Result {
                    try cache.resolve(deadline: 84, now: { 2 }) { deadline in
                        #expect(deadline == 84)
                        return "/validated/developer"
                    }
                })
            succeeded.signal()
        }.start()
        // This completes while the first discovery remains paused: discovery cannot own the cache mutex.
        try #require(succeeded.wait(timeout: .now() + 10) == .success)
        release.signal()
        try #require(failed.wait(timeout: .now() + 10) == .success)
        #expect(outcomes.snapshot.failures == [.budget])
        #expect(outcomes.snapshot.directories == ["/validated/developer"])
        let cached = try cache.resolve(deadline: 90, now: { 3 }) { _ in throw GitCommand.Failure.command }
        #expect(cached == "/validated/developer")
    }
}
