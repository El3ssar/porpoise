import Foundation

@main struct DiffBenchmark {
    static func main() throws {
        let left = (0..<100000).map { "left-\($0)\n" }.joined()
        let right = (0..<100000).map { "right-\($0)\n" }.joined()
        let start = ProcessInfo.processInfo.systemUptime
        let complete = TextDifference(left: left, right: right)
        let completeMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var checks = 0
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        do {
            _ = try TextDifference(
                left: left, right: right,
                checkCancellation: {
                    checks += 1
                    if checks == 20 { throw CancellationError() }
                })
            preconditionFailure("Cancellation was ignored")
        } catch is CancellationError {}
        print(
            "Text diff 100k unrelated lines: completed \(completeMS) ms (\(complete.changes.count) changes); superseded at checkpoint 20 after \((ProcessInfo.processInfo.systemUptime - cancelledAt) * 1000) ms"
        )
    }
}
