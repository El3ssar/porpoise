import Foundation
import PorpoiseCore

/// Main-thread request ownership for live Compare. A newer location invalidates both a pending debounce and
/// an in-flight scan; callers publish only results whose request is still accepted.
public final class ComparisonRefresh {
    public struct Request: Sendable {
        public let left: URL, right: URL
        public let cancellation: DiskCancellation
        fileprivate let generation: Int
    }
    private var generation = 0
    private var pending: DispatchWorkItem?
    public private(set) var current: Request?
    public var onStart: ((Request) -> Void)?
    public init() {}
    @discardableResult public func schedule(left: URL, right: URL, delay: TimeInterval = 0.15) -> Request {
        stop()
        let request = Request(left: left, right: right, cancellation: DiskCancellation(), generation: generation)
        current = request
        if delay <= 0 {
            onStart?(request)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.accepts(request) else { return }
                self.pending = nil; self.onStart?(request)
            }
            pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        return request
    }
    public func accepts(_ request: Request) -> Bool {
        current?.generation == request.generation && !request.cancellation.isCancelled
    }
    public func stop() {
        pending?.cancel(); pending = nil; current?.cancellation.cancel(); current = nil; generation += 1
    }
    deinit { pending?.cancel(); current?.cancellation.cancel() }
}
