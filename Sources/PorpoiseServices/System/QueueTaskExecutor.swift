import Foundation

/// Runs a task's code on a serial dispatch queue of its own instead of Swift's shared cooperative threads. Those are
/// as many as the cores, and a busy process (a full test run on CI's 3-core runner) can keep every one of them
/// occupied for a long time; such a queue always gets a thread.
final class QueueTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS) {
        queue = DispatchQueue(label: label, qos: qos, autoreleaseFrequency: .workItem)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
