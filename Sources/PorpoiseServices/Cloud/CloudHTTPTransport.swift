import Foundation

/// Bounded streaming and injectable HTTP boundary shared by providers. Status/error policy belongs to the adapter.
public struct CloudHTTPTransport: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let send: Send
    private let network: Bool
    public init(send: Send? = nil, invalidResponse: @escaping @Sendable () -> Error = { URLError(.badServerResponse) }) {
        network = send == nil
        self.send =
            send ?? { request in
                let (data, response) = try await Self.session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw invalidResponse() }
                return (data, response)
            }
    }
    /// No disk cache, cookies or credential storage: account data (file names, owners) never lands in Cache.db.
    static let session = URLSession(configuration: .ephemeral)
    /// The same, answering a redirect with the redirect itself: a bearer sent to an API host never follows it elsewhere.
    static let unredirected = URLSession(configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil)
    /// This transport, giving 3xx responses back instead of following them (an injected one is used as it is).
    public var withoutRedirects: CloudHTTPTransport {
        guard network else { return self }
        return CloudHTTPTransport(send: { request in
            let (data, response) = try await Self.unredirected.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        })
    }
    public func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation(); return try await send(request)
    }
    public func stream(_ request: URLRequest, consume: (Data, HTTPURLResponse) async throws -> Void) async throws -> HTTPURLResponse {
        if network { return try await HTTPFileStream.receive(request, consume: consume) }
        let (data, response) = try await self.response(request)
        try await consume(data, response); return response
    }
    /// A form POST (OAuth token endpoints): the provider reads the answer.
    public func postForm(_ url: URL, _ values: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(values)
        return try await response(request)
    }
    public static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(
            values.sorted { $0.key < $1.key }.map {
                "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").utf8)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
