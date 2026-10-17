import Darwin
import Foundation

/// Binds only 127.0.0.1 on an OS-selected port. No web server or callback URL is exposed on the LAN.
public final class CloudOAuthLoopback: @unchecked Sendable {
    public let redirectURL: URL
    private let descriptor: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var waiting = false

    public init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CloudOAuthError.invalidResponse }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw CloudOAuthError.invalidResponse }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); throw CloudOAuthError.invalidResponse }
        descriptor = fd
        redirectURL = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/oauth/callback")!
    }

    deinit { close(descriptor) }
    public func cancel() { lock.withLock { cancelled = true } }

    public func callback(timeout: TimeInterval = 180) async throws -> URL {
        guard
            lock.withLock({
                if waiting { return false }; waiting = true; return true
            })
        else { throw CloudOAuthError.cancelled }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread { [self] in
                    do { continuation.resume(returning: try receive(timeout: timeout)) } catch { continuation.resume(throwing: error) }
                }.start()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func ready(_ fd: Int32, deadline: Date) throws {
        while true {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            if Date() >= deadline { throw CloudOAuthError.timeout }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&p, 1, 100)
            if result > 0 { return }
            if result < 0, errno != EINTR { throw CloudOAuthError.invalidResponse }
        }
    }

    private func receive(timeout: TimeInterval) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try ready(descriptor, deadline: deadline)
            let fd = accept(descriptor, nil, nil)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var bytes = Data()
            while bytes.range(of: Data("\r\n\r\n".utf8)) == nil, bytes.count < 8192 {
                try ready(fd, deadline: deadline)
                var buffer = [UInt8](repeating: 0, count: 2048)
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            let line = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/oauth/callback?"),
                let url = URL(string: String(parts[1]), relativeTo: redirectURL)?.absoluteURL,
                url.host == "127.0.0.1", url.port == redirectURL.port
            else {
                respond(fd, status: "404 Not Found", body: "Not found.")
                continue
            }
            respond(fd, status: "200 OK", body: "Sign-in response received. You can return to Porpoise.")
            return url
        }
    }

    private func respond(_ fd: Int32, status: String, body: String) {
        let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
        _ = response.withCString { send(fd, $0, response.utf8.count, 0) }
    }
}
