import Foundation

/// Streams network buffers with backpressure. The consumer finishes each buffer before the task resumes.
/// Kept provider-neutral so other cloud transports can use the same bounded-memory HTTP path.
final class HTTPFileStream: Sendable {
    enum Event: Sendable { case response(HTTPURLResponse), data(Data) }
    fileprivate let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private init(_ continuation: AsyncThrowingStream<Event, Error>.Continuation) { self.continuation = continuation }

    /// One session for every stream: its connections are reused (a ranged download makes many requests to one host),
    /// where a session per request opened a connection, TLS included, each time. Like the ephemeral session per
    /// request it replaces, it keeps no cookies, cache or credentials.
    private static let streams = Streams()
    // OperationQueue.underlyingQueue is borrowed by the SDK. Keep its executor alive for the shared session.
    private static let delegateExecutor = DispatchQueue(label: "porpoise.http-file-stream", qos: .userInitiated)
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // Its own thread, never Swift's cooperative ones: a plain queue's delegate calls waited for one, and with
        // every cooperative thread taken (a full test run on CI's 3-core runner) a range response's upstream head
        // came after the preview server's ten-second idle deadline had closed the response (W-138).
        queue.underlyingQueue = delegateExecutor
        return URLSession(configuration: configuration, delegate: streams, delegateQueue: queue)
    }()

    static func receive(_ request: URLRequest, consume: (Data, HTTPURLResponse) async throws -> Void) async throws -> HTTPURLResponse {
        let (events, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
        let stream = HTTPFileStream(continuation)
        let task = session.dataTask(with: request)
        streams.add(stream, for: task)
        defer {
            task.cancel()
            streams.remove(task)
        }
        return try await withTaskCancellationHandler {
            task.resume()
            var response: HTTPURLResponse?
            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .response(let head): response = head
                case .data(let data):
                    guard let response else { throw URLError(.badServerResponse) }
                    try await consume(data, response)
                    task.resume()
                }
            }
            guard let response else { throw URLError(.badServerResponse) }
            return response
        } onCancel: {
            task.cancel()
        }
    }

    /// The shared session's delegate: hands each task's events to its stream.
    // The registry is locked; published streams and their continuations are immutable/Sendable.
    private final class Streams: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [Int: HTTPFileStream] = [:]
        func add(_ stream: HTTPFileStream, for task: URLSessionTask) { lock.withLock { streams[task.taskIdentifier] = stream } }
        func remove(_ task: URLSessionTask) { _ = lock.withLock { streams.removeValue(forKey: task.taskIdentifier) } }
        private func stream(_ task: URLSessionTask) -> HTTPFileStream? { lock.withLock { streams[task.taskIdentifier] } }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let stream = stream(dataTask) else { completionHandler(.cancel); return }
            guard let response = response as? HTTPURLResponse else {
                completionHandler(.cancel); stream.continuation.finish(throwing: URLError(.badServerResponse)); return
            }
            stream.continuation.yield(.response(response))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            dataTask.suspend()
            stream(dataTask)?.continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let stream = stream(task) else { return }
            if let error { stream.continuation.finish(throwing: error) } else { stream.continuation.finish() }
        }
    }
}
