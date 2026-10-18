import Foundation

/// What a provider makes of a response: done, worth sending again (the service is busy, or failed before doing
/// anything) with the error to give if it stays so, or an error in the provider's own terms.
public enum CloudHTTPOutcome: Sendable {
    case done
    case retry(Error)
    case fail(Error)
}

/// Every authorized request to a cloud service, the same for each provider: the account's bearer token, renewed once
/// when the service refuses it, and a bounded backoff while the service is busy, honoring its Retry-After.
public struct CloudAuthorizedClient: Sendable {
    /// The account's access token; `rejected` is the one the service just refused (renew it).
    public typealias Token = @Sendable (_ rejected: String?) async throws -> String
    /// The provider's reading of a response; `idempotent`: sending it again can't do anything twice.
    public typealias Classify = @Sendable (_ body: Data, _ response: HTTPURLResponse, _ idempotent: Bool) -> CloudHTTPOutcome
    public typealias Receive = (Data, HTTPURLResponse) async throws -> Void

    public let transport: CloudHTTPTransport
    let token: Token
    let classify: Classify
    let attempts: Int
    let wait: @Sendable (TimeInterval) async throws -> Void
    /// How a pause before sending again is spent: sleeping. Tests pass a recorder to see each pause without waiting.
    public static let defaultWait: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    public init(
        transport: CloudHTTPTransport, token: @escaping Token, classify: @escaping Classify, attempts: Int = 5,
        wait: @escaping @Sendable (TimeInterval) async throws -> Void = CloudAuthorizedClient.defaultWait
    ) {
        self.transport = transport; self.token = token; self.classify = classify; self.attempts = max(1, attempts); self.wait = wait
    }

    /// Sends `request`. With `receive`, a successful body is streamed to it (an error body is kept, up to 64 KB, for
    /// the provider to read); only a response that delivered nothing is ever sent again. `onWait` hears each pause.
    public func send(
        _ request: URLRequest, idempotent: Bool, receive: Receive? = nil, before: (() async throws -> Void)? = nil,
        onWait: ((TimeInterval) -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        var bearer = try await token(nil)
        var renewed = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            try await before?()
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            let (body, response) = try await exchange(request, receive: receive)
            if response.statusCode == 401, !renewed {
                renewed = true
                bearer = try await token(bearer)
                continue
            }
            switch classify(body, response, idempotent) {
            case .done: return (body, response)
            case .fail(let error): throw error
            case .retry(let error):
                attempt += 1
                guard attempt < attempts else { throw error }
                let delay = Self.delay(response, attempt: attempt - 1)
                onWait?(delay)
                try await wait(delay + Double.random(in: 0...0.05))
            }
        }
    }

    private func exchange(_ request: URLRequest, receive: Receive?) async throws -> (Data, HTTPURLResponse) {
        guard let receive else { return try await transport.response(request) }
        var errorBody = Data()
        let response = try await transport.stream(request) { chunk, head in
            if (200..<300).contains(head.statusCode) {
                try await receive(chunk, head)
            } else {
                errorBody.append(chunk.prefix(max(0, 65536 - errorBody.count)))
            }
        }
        return (errorBody, response)
    }

    /// The service's Retry-After when it gives one, else 1, 2, 4, 8… seconds; never more than 30.
    static func delay(_ response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        let asked = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        return min(30, max(0, asked ?? pow(2, Double(attempt))))
    }
}
