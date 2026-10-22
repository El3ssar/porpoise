import Foundation

/// Synchronous on the main thread; ordered delivery on the main queue from callback threads. UI callbacks use
/// this boundary rather than losing their actor contract when stored in a provider-neutral closure.
enum MainActorDelivery {
    nonisolated static func deliver(_ action: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { action() } } else { DispatchQueue.main.async { action() } }
    }
}
