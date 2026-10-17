import Foundation

/// Streams network buffers with backpressure. The consumer finishes each buffer before the task resumes.
/// Kept provider-neutral so other cloud transports can use the same bounded-memory HTTP path.
final class HTTPFileStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event { case response(HTTPURLResponse), data(Data) }
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation!
    private var session: URLSession!
    private var task: URLSessionDataTask!

    static func receive(_ request: URLRequest, consume: (Data, HTTPURLResponse) async throws -> Void) async throws -> HTTPURLResponse {
        let delegate = HTTPFileStream()
        let events = AsyncThrowingStream<Event, Error> { delegate.continuation = $0 }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        delegate.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
        delegate.task = delegate.session.dataTask(with: request)
        defer { delegate.session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            delegate.task.resume()
            var response: HTTPURLResponse?
            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .response(let head): response = head
                case .data(let data):
                    guard let response else { throw URLError(.badServerResponse) }
                    try await consume(data, response)
                    delegate.task.resume()
                }
            }
            guard let response else { throw URLError(.badServerResponse) }
            return response
        } onCancel: {
            delegate.task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); continuation.finish(throwing: URLError(.badServerResponse)); return
        }
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataTask.suspend()
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
