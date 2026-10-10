import Foundation
import Network
import PorpoiseCore

/// Minimal read-only HTTP/1.1 file server for the preview stream (AVPlayer only streams HLS over HTTP).
///
/// - Listens on 127.0.0.1 only.
/// - Every URL starts with a random secret, so other local users/processes can't read the stream.
/// - Serves regular files strictly inside `root`: "..", hidden components and symlinks leading out are refused.
/// - Files are memory-mapped and sent in chunks, never read whole into memory.
final class LocalFileServer {
    private static let maxRequestSize = 16_384
    private static let chunkSize = 1 << 20
    private static let startTimeout: TimeInterval = 2

    private var listener: NWListener?
    private var port: UInt16?
    private var root: URL?
    private let secret = UUID().uuidString
    private let queue = DispatchQueue(label: "porpoise.preview-server")

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

    // MARK: Request handling (on `queue`)

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receiveHead(c, buffer: Data())
    }

    /// Reads until the end of the request head (it may arrive in several packets).
    private func receiveHead(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil || buf.count >= Self.maxRequestSize {
                self.respond(c, request: buf)
            } else {
                self.receiveHead(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, request: Data) {
        let line = String(decoding: request.prefix(while: { $0 != 13 && $0 != 10 }), as: UTF8.self)
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return send(c, status: "400 Bad Request") }
        let method = parts[0]
        guard method == "GET" || method == "HEAD" else { return send(c, status: "405 Method Not Allowed") }
        guard let file = resolve(String(parts[1])), let data = try? Data(contentsOf: file, options: .alwaysMapped) else {
            return send(c, status: "404 Not Found")
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(Self.contentType(file.pathExtension))\r\nContent-Length: \(data.count)\r\n"
            + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, method == "GET", let self else { c.cancel(); return }
            self.sendBody(c, data, from: 0)
        })
    }

    private func sendBody(_ c: NWConnection, _ data: Data, from offset: Int) {
        guard offset < data.count else { c.cancel(); return }
        let end = min(offset + Self.chunkSize, data.count)
        c.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { c.cancel(); return }
            self.sendBody(c, data, from: end)
        })
    }

    private func send(_ c: NWConnection, status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in c.cancel() })
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
