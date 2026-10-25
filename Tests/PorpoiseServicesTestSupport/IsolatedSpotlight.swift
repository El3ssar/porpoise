import Testing

/// Tests that deliberately stall the process-wide Spotlight queue must take turns with tests that need an answer.
/// `.serialized` only orders tests within one suite; this scope also excludes other suites, without blocking a thread.
public struct IsolatedSpotlight: TestTrait, SuiteTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        await SpotlightTurn.shared.acquire()
        var failure: Error?
        do { try await function() } catch { failure = error }
        await SpotlightTurn.shared.release()
        if let failure { throw failure }
    }
}

extension Trait where Self == IsolatedSpotlight {
    public static var isolatedSpotlight: Self { IsolatedSpotlight() }
}

private actor SpotlightTurn {
    static let shared = SpotlightTurn()
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
