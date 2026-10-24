import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Holds one real fake-server response until the test releases it, even after cancellation.
final class CloudBackendRequestGate: @unchecked Sendable {
    private let matches: @Sendable (URLRequest) -> Bool
    private let count = Locked(0)
    private let release = Locked<Callback<Void>?>(nil)
    let cancelled = Flag()
    init(matches: @escaping @Sendable (URLRequest) -> Bool) { self.matches = matches }
    var waiting: Bool { release.value != nil }
    func resume() { release.value?.resume() }
    var http: CloudHTTPTransport {
        CloudHTTPTransport(send: { [self] request in
            let response = try await CloudHTTPTransport().response(request)
            guard matches(request),
                count.change({
                    $0 += 1; return $0
                }) == 1
            else { return response }
            try await withTaskCancellationHandler {
                try await awaitCallback { callback in release.change { $0 = callback } }
            } onCancel: {
                cancelled.set()
            }
            return response
        })
    }
}
