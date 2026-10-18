import Foundation
import Network
import PorpoiseCore
import PorpoiseFileSystem

/// Minimal read-only HTTP/1.1 file server for the preview stream (AVPlayer only streams HLS over HTTP).
///
/// - Listens on 127.0.0.1 only.
/// - Every URL starts with a random secret, so other local users/processes can't read the stream.
/// - Serves regular files strictly inside `root`: "..", hidden components and symlinks leading out are refused.
/// - Files are memory-mapped and sent in chunks, never read whole into memory.
/// - At most eight connections are admitted, including incomplete requests.
/// - Request heads and idle responses have separate deadlines; stopping closes every admitted connection.
// Connection state is confined to `queue`; callers serialize start/stop (the preview owner or a test fixture).
final class LocalFileServer: @unchecked Sendable {
    private static let maxRequestSize = 16_384
    private static let chunkSize = 1 << 20
    private static let startTimeout: TimeInterval = 2
    /// Range tasks must start and resume before their real-time idle deadline even when the shared cooperative
    /// pool is occupied. This also carries the executor preference through the provider's asynchronous read.
    private static let responder = QueueTaskExecutor(label: "porpoise.preview-response", qos: .userInitiated)

    struct RangeSource: Sendable {
        let size: Int64
        let contentType: String
        let read: @Sendable (Range<Int64>) async throws -> Data
    }
    private var source: RangeSource?
    private var flights: [ObjectIdentifier: (NWConnection, Task<Void, Never>)] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var idleTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var maxConnections = 8
    private var sendIdleTimeout: TimeInterval = 10
    var connectionLimit: Int {
        get { queue.sync { maxConnections } }
        set { queue.sync { maxConnections = newValue } }
    }
    var sendTimeout: TimeInterval {
        get { queue.sync { sendIdleTimeout } }
        set { queue.sync { sendIdleTimeout = newValue } }
    }
    var activeConnectionCount: Int { queue.sync { connections.count } }
    private var listener: NWListener?
    private var port: UInt16?
    private var root: URL?
    private let secret = UUID().uuidString
    private let queue = DispatchQueue(label: "porpoise.preview-server")
    /// How long a connection may take to send its request head.
    private var requestTimeout: TimeInterval = 10
    var headTimeout: TimeInterval {
        get { queue.sync { requestTimeout } }
        set { queue.sync { requestTimeout = newValue } }
    }

    /// Starts once (later calls just update the root) and returns the base URL to put paths under.
    func start(root: URL) -> URL? {
        queue.sync { self.root = root.resolvingSymlinksInPath() }
        if port == nil {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            guard let l = try? NWListener(using: params) else { return nil }
            let ready = DispatchSemaphore(value: 0)
            l.stateUpdateHandler = { s in
                switch s {
                case .ready, .failed, .cancelled: ready.signal()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: queue)
            _ = ready.wait(timeout: .now() + Self.startTimeout)
            guard case .ready = l.state, let p = l.port?.rawValue else { l.cancel(); return nil }
            listener = l
            port = p
        }
        guard let p = port else { return nil }
        return URL(string: "http://127.0.0.1:\(p)/\(secret)/")
    }

    /// An authenticated on-demand source. Its secret URL never contains an upstream URL or credential.
    func start(source: RangeSource) -> URL? {
        queue.sync { self.source = source }
        return start(root: FileManager.default.temporaryDirectory)?.appendingPathComponent("media")
    }

    /// Stops listening (for tests: the app keeps its one server for as long as it runs).
    func stop() {
        queue.sync {
            source = nil
            for (connection, task) in flights.values { task.cancel(); connection.cancel() }
            flights.removeAll()
            for c in connections.values { c.cancel() }
            connections.removeAll()
            for timer in idleTimers.values { timer.cancel() }
            idleTimers.removeAll()
        }
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: Request handling (on `queue`)

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        guard connections.count < maxConnections else { c.cancel(); return }
        let id = ObjectIdentifier(c)
        connections[id] = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeValue(forKey: id)
                self?.idleTimers.removeValue(forKey: id)?.cancel()
                self?.flights.removeValue(forKey: id)?.1.cancel()
            default: break
            }
        }
        let answered = Flag()
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak c] in if !answered.isSet { c?.cancel() } }
        receiveHead(c, buffer: Data(), answered: answered)
    }

    /// Set once a connection's request has been read (only touched on `queue`).
    private final class Flag { var isSet = false }

    /// Reads until the end of the request head (it may arrive in several packets).
    private func receiveHead(_ c: NWConnection, buffer: Data, answered: Flag) {
        c.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil || buf.count >= Self.maxRequestSize {
                answered.isSet = true
                self.respond(c, request: buf)
            } else {
                self.receiveHead(c, buffer: buf, answered: answered)
            }
        }
    }

    private func respond(_ c: NWConnection, request: Data) {
        guard connections[ObjectIdentifier(c)] != nil else { return }
        // Bound the response even while an upstream read task is waiting to be scheduled.
        armSendDeadline(c)
        let line = String(decoding: request.prefix(while: { $0 != 13 && $0 != 10 }), as: UTF8.self)
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return send(c, status: "400 Bad Request") }
        let method = parts[0]
        guard method == "GET" || method == "HEAD" else { return send(c, status: "405 Method Not Allowed") }
        if let source {
            guard parts[1] == "/\(secret)/media" else { return send(c, status: "404 Not Found") }
            return respond(c, source: source, request: request, headOnly: method == "HEAD")
        }
        guard let file = resolve(String(parts[1])), let data = try? Data(contentsOf: file, options: .alwaysMapped) else {
            return send(c, status: "404 Not Found")
        }
        let head =
            "HTTP/1.1 200 OK\r\nContent-Type: \(Self.contentType(file.pathExtension))\r\nContent-Length: \(data.count)\r\n"
            + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        sendContent(
            c, data: Data(head.utf8),
            completion: .contentProcessed { [weak self] error in
                guard error == nil, method == "GET", let self else { c.cancel(); return }
                self.sendBody(c, data, from: 0)
            })
    }

    private func respond(_ c: NWConnection, source: RangeSource, request: Data, headOnly: Bool) {
        let headers = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").dropFirst()
        let ranges = headers.filter { $0.lowercased().hasPrefix("range:") }
        let range: Range<Int64>
        do { range = try Self.byteRange(ranges.first.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }, size: source.size) } catch
        { return send(c, status: "416 Range Not Satisfiable") }
        guard ranges.count <= 1 else { return send(c, status: "416 Range Not Satisfiable") }
        let ranged = !ranges.isEmpty
        var head = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(source.contentType)\r\n"
        head += "Content-Length: \(range.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if ranged { head += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(source.size)\r\n" }
        head += "\r\n"
        let id = ObjectIdentifier(c)
        let task = Task(executorPreference: Self.responder) { [weak self] in
            guard let self else { c.cancel(); return }
            do {
                try await self.send(c, data: Data(head.utf8))
                if !headOnly {
                    var offset = range.lowerBound
                    while offset < range.upperBound {
                        try Task.checkCancellation()
                        let end = min(range.upperBound, offset + 1024 * 1024)
                        let data = try await source.read(offset..<end)
                        guard data.count == end - offset else { throw DriveError.invalidResponse }
                        try Task.checkCancellation()
                        try await self.send(c, data: data)
                        offset = end
                    }
                }
            } catch { /* Closing an incomplete response makes AVPlayer surface the load error. */  }
            c.cancel()
        }
        flights[id] = (c, task)
    }

    /// Every send, including the response head, is bounded. Progress replaces the idle deadline.
    private func sendContent(_ c: NWConnection, data: Data, completion: NWConnection.SendCompletion) {
        let id = ObjectIdentifier(c)
        guard connections[id] != nil else { c.cancel(); return }
        armSendDeadline(c)
        c.send(content: data, completion: completion)
    }

    private func armSendDeadline(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        idleTimers.removeValue(forKey: id)?.cancel()
        let timer = DispatchWorkItem { [weak c] in c?.cancel() }
        idleTimers[id] = timer
        queue.asyncAfter(deadline: .now() + sendIdleTimeout, execute: timer)
    }

    private func send(_ c: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.connections[ObjectIdentifier(c)] != nil else {
                    continuation.resume(throwing: CancellationError()); return
                }
                self.sendContent(
                    c, data: data,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
            }
        }
    }

    static func byteRange(_ value: String?, size: Int64) throws -> Range<Int64> {
        guard size >= 0 else { throw DriveError.invalidResponse }
        guard let value else { return 0..<size }
        guard value.hasPrefix("bytes="), !value.contains(","), size > 0 else { throw DriveError.invalidResponse }
        let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { throw DriveError.invalidResponse }
        if bounds[0].isEmpty {
            guard let count = Int64(bounds[1]), count > 0 else { throw DriveError.invalidResponse }
            return max(0, size - count)..<size
        }
        guard let start = Int64(bounds[0]), start >= 0, start < size else { throw DriveError.invalidResponse }
        if bounds[1].isEmpty { return start..<size }
        guard let end = Int64(bounds[1]), end >= start else { throw DriveError.invalidResponse }
        return start..<(min(end, size - 1) + 1)
    }

    private func sendBody(_ c: NWConnection, _ data: Data, from offset: Int) {
        guard offset < data.count else { c.cancel(); return }
        let end = min(offset + Self.chunkSize, data.count)
        sendContent(
            c, data: data.subdata(in: offset..<end),
            completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { c.cancel(); return }
                self.sendBody(c, data, from: end)
            })
    }

    private func send(_ c: NWConnection, status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        sendContent(c, data: Data(head.utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    private func resolve(_ target: String) -> URL? {
        root.flatMap { Escaping.servedFile(for: target, root: $0, secret: secret) }
    }

    static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "m4s": return "video/iso.segment"
        default: return "video/mp4"
        }
    }
}
