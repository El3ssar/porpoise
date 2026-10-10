import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The preview stream's HTTP server, for real: started on a scratch folder and asked over TCP.
@Suite struct LocalFileServerTests {
    /// A response as raw text head plus body bytes.
    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    /// A server on a scratch folder: root/stream/{index.m3u8, seg 1.m4s, big.mp4, .hidden}, a secret next to the root
    /// and symlinks inside pointing in and out. Stopped by `stop()` (call it in a defer).
    final class Fixture {
        let scratch: Scratch
        let server = LocalFileServer()
        let base: URL
        let port: UInt16
        let secret: String
        let big: Data

        init(_ name: String = #function) throws {
            scratch = try Scratch(name)
            try scratch.file("root/stream/index.m3u8", "#EXTM3U\n#EXTINF:4,\nseg 1.m4s\n")
            try scratch.file("root/stream/seg 1.m4s", "segment")
            try scratch.file("root/stream/.hidden", "hidden")
            try scratch.file("root/.secretfolder/x.m4s", "hidden folder")
            try scratch.file("outside.txt", "private")
            // 3.5 MB of varied bytes: sent in several chunks.
            var b = Data(count: 3_500_000)
            b.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) } }
            big = b
            try big.write(to: scratch.path("root/stream/big.mp4"))
            try scratch.symlink("root/stream/out", to: scratch.path("outside.txt").path)
            try scratch.symlink("root/stream/outdir", to: scratch.url.path)
            try scratch.symlink("root/stream/in", to: scratch.path("root/stream/index.m3u8").path)
            try scratch.symlink("root/stream/etc", to: "/etc/hosts")
            base = try #require(server.start(root: scratch.path("root")))
            port = try #require(base.port.map(UInt16.init))
            secret = base.pathComponents[1]
        }

        func stop() { server.stop() }

        /// Sends `request` as is and reads until the server closes.
        func raw(_ request: Data, halfClose: Bool = false) throws -> Response {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }
            _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if halfClose { shutdown(fd, SHUT_WR) }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return try Self.parse(data)
        }

        func get(_ target: String, method: String = "GET", extra: String = "") throws -> Response {
            try raw(Data("\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(extra)\r\n".utf8))
        }

        static func parse(_ data: Data) throws -> Response {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { throw POSIXError(.EBADMSG) }
            let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let status = Int(lines[0].split(separator: " ")[1]) ?? 0
            var headers: [String: String] = [:]
            for l in lines.dropFirst() {
                let kv = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { headers[kv[0].lowercased()] = kv[1] }
            }
            return Response(status: status, headers: headers, body: data[end.upperBound...])
        }
    }

    // MARK: Serving

    @Test func servesFilesWithTheirTypeAndLength() throws {
        let f = try Fixture(); defer { f.stop() }
        #expect(f.base.host == "127.0.0.1")
        #expect(f.secret.count == 36)
        let r = try f.get("/\(f.secret)/stream/index.m3u8")
        #expect(r.status == 200)
        #expect(r.headers["content-type"] == "application/vnd.apple.mpegurl")
        #expect(r.headers["content-length"] == "\(r.body.count)")
        #expect(r.headers["cache-control"] == "no-cache")
        #expect(r.headers["connection"] == "close")
        #expect(String(decoding: r.body, as: UTF8.self).hasPrefix("#EXTM3U"))
        let seg = try f.get("/\(f.secret)/stream/seg%201.m4s?x=1")
        #expect(seg.status == 200 && seg.headers["content-type"] == "video/iso.segment" && seg.body == Data("segment".utf8))
        // A symlink staying inside the root is fine.
        #expect(try f.get("/\(f.secret)/stream/in").status == 200)
    }

    @Test func largeFilesArriveWholeInChunks() throws {
        let f = try Fixture(); defer { f.stop() }
        let r = try f.get("/\(f.secret)/stream/big.mp4")
        #expect(r.status == 200)
        #expect(r.headers["content-type"] == "video/mp4")
        #expect(r.headers["content-length"] == "\(f.big.count)")
        #expect(r.body == f.big)
    }

    @Test func throughURLSession() async throws {
        let f = try Fixture(); defer { f.stop() }
        let url = f.base.appendingPathComponent("stream").appendingPathComponent("seg 1.m4s")
        let (data, resp) = try await URLSession.shared.data(from: url)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == Data("segment".utf8))
    }

    @Test func headSendsTheHeadOnly() throws {
        let f = try Fixture(); defer { f.stop() }
        let r = try f.get("/\(f.secret)/stream/big.mp4", method: "HEAD")
        #expect(r.status == 200)
        #expect(r.headers["content-length"] == "\(f.big.count)")
        #expect(r.body.isEmpty)
    }

    @Test func rangeRequestsGetTheWholeFile() throws {
        // No range support: a Range header is ignored and the whole file is sent with 200 (valid HTTP).
        let f = try Fixture(); defer { f.stop() }
        let r = try f.get("/\(f.secret)/stream/big.mp4", extra: "Range: bytes=0-9\r\n")
        #expect(r.status == 200)
        #expect(r.body == f.big)
    }

    @Test func aHeadInSeveralPacketsOrWithoutItsBlankLine() throws {
        let f = try Fixture(); defer { f.stop() }
        // No final blank line, but the client closes its side: answered with what arrived.
        let r = try f.raw(Data("GET /\(f.secret)/stream/seg%201.m4s HTTP/1.1\r\nHost: x".utf8), halfClose: true)
        #expect(r.status == 200 && r.body == Data("segment".utf8))
    }

    @Test func manyConcurrentRequests() async throws {
        let f = try Fixture(); defer { f.stop() }
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<24 {
                group.addTask {
                    let r = try f.get(i % 2 == 0 ? "/\(f.secret)/stream/big.mp4" : "/\(f.secret)/stream/index.m3u8")
                    return r.status == 200 && (i % 2 == 1 || r.body == f.big)
                }
            }
            return try await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.count == 24 && results.allSatisfy { $0 })
    }

    @Test func startingAgainKeepsThePortAndSecretAndMovesTheRoot() throws {
        let f = try Fixture(); defer { f.stop() }
        try f.scratch.file("root2/other.m4s", "two")
        #expect(f.server.start(root: f.scratch.path("root2")) == f.base)
        #expect(try f.get("/\(f.secret)/other.m4s").body == Data("two".utf8))
        #expect(try f.get("/\(f.secret)/stream/index.m3u8").status == 404)
    }

    @Test func twoServersHaveDifferentSecrets() throws {
        let a = try Fixture(), b = try Fixture()
        defer { a.stop(); b.stop() }
        #expect(a.secret != b.secret && a.port != b.port)
        #expect(try a.get("/\(b.secret)/stream/index.m3u8").status == 404)
    }

    // MARK: Refusing

    @Test func refusesWithoutTheRightSecret() throws {
        let f = try Fixture(); defer { f.stop() }
        for target in [
            "/stream/index.m3u8", "/WRONG/stream/index.m3u8", "/\(f.secret.lowercased())/stream/index.m3u8",
            "/\(f.secret.dropLast())/stream/index.m3u8", "/x/\(f.secret)/stream/index.m3u8", "/", "*",
            "http://127.0.0.1:\(f.port)/\(f.secret)/stream/index.m3u8",
        ] {
            let r = try f.get(target)
            #expect(r.status == 404 && r.body.isEmpty, "\(target)")
        }
    }

    @Test func refusesPathsLeavingTheRoot() throws {
        let f = try Fixture(); defer { f.stop() }
        let s = f.secret
        let bad = [
            "/\(s)/../outside.txt", "/\(s)/stream/../../outside.txt", "/\(s)/%2e%2e/outside.txt", "/\(s)/%2E%2E/outside.txt",
            "/\(s)/stream%2F..%2F..%2Foutside.txt", "/\(s)/%252e%252e/outside.txt", "/\(s)/..%2Foutside.txt",
            "/\(s)/stream/..\\..\\outside.txt", "/\(s)/stream/%5C..%5Coutside.txt", "/\(s)/stream/index.m3u8%00.jpg",
            "/\(s)/stream/%00", "/\(s)//etc/hosts", "/\(s)/%2Fetc%2Fhosts", "/\(s)/stream/etc", "/\(s)/stream/out",
            "/\(s)/stream/outdir/outside.txt", "/\(s)/stream/.hidden", "/\(s)/stream/%2Ehidden", "/\(s)/.secretfolder/x.m4s",
            "/\(s)/stream", "/\(s)/stream/", "/\(s)/", "/\(s)", "/\(s)/stream/missing.m4s", "/\(s)/stream/%ZZ",
            "/\(s)/./stream/index.m3u8", "/\(s)/stream/./index.m3u8",
        ]
        for target in bad {
            let r = try f.get(target)
            #expect(r.status == 404, "\(target)")
            #expect(!String(decoding: r.body, as: UTF8.self).contains("private"), "\(target)")
            #expect(!String(decoding: r.body, as: UTF8.self).contains("localhost"), "\(target)")
        }
    }

    @Test func refusesOtherMethods() throws {
        let f = try Fixture(); defer { f.stop() }
        for m in ["POST", "PUT", "DELETE", "OPTIONS", "TRACE", "CONNECT", "PATCH", "get", "Head", "GETX"] {
            let r = try f.get("/\(f.secret)/stream/index.m3u8", method: m)
            #expect(r.status == 405 && r.body.isEmpty, "\(m)")
        }
    }

    @Test func malformedRequests() throws {
        let f = try Fixture(); defer { f.stop() }
        #expect(try f.raw(Data("GARBAGE\r\n\r\n".utf8)).status == 400)
        #expect(try f.raw(Data("\r\n\r\n".utf8)).status == 400)
        #expect(try f.raw(Data(), halfClose: true).status == 400)
        #expect(try f.raw(Data([0xff, 0xfe, 0x00, 0x20, 0x0d, 0x0a, 0x0d, 0x0a])).status == 400)
        // A path far longer than the request limit: cut off, and refused.
        let long = "/\(f.secret)/" + String(repeating: "a/", count: 20_000) + "x"
        #expect(try f.get(long).status == 404)
        let longName = "/\(f.secret)/" + String(repeating: "n", count: 5000)
        #expect(try f.get(longName).status == 404)
        // A huge header after a valid request line: the request line still decides.
        let hugeHeader = "X-Junk: " + String(repeating: "j", count: 40_000) + "\r\n"
        #expect(try f.get("/\(f.secret)/stream/seg%201.m4s", extra: hugeHeader).status == 200)
        // The server still answers afterwards.
        #expect(try f.get("/\(f.secret)/stream/index.m3u8").status == 200)
    }

    // MARK: Where it listens

    /// A client that connects and never finishes its request is disconnected, instead of holding a connection open.
    @Test func idleConnectionsAreClosed() throws {
        let f = try Fixture()
        defer { f.stop() }
        f.server.headTimeout = 0.5
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = f.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(ok == 0)
        _ = "GET /\(f.secret)/stream/index.m3u8 HTTP/1.1\r\n".withCString { send(fd, $0, strlen($0), 0) }  // no blank line
        let started = Date()
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, 0)
        #expect(n == 0)  // closed by the server, not timed out on our side
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func listensOnLoopbackOnly() throws {
        let f = try Fixture(); defer { f.stop() }
        // Every other IPv4 address of this Mac, and IPv6 loopback, is refused.
        var addrs: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let i = p {
                if let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET) {
                    var sin = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
                    let s = String(cString: buf)
                    if !s.hasPrefix("127.") { addrs.append(s) }
                }
                p = i.pointee.ifa_next
            }
            freeifaddrs(first)
        }
        for a in addrs { #expect(!Self.canConnect(family: AF_INET, address: a, port: f.port), "\(a)") }
        #expect(!Self.canConnect(family: AF_INET6, address: "::1", port: f.port))
        #expect(Self.canConnect(family: AF_INET, address: "127.0.0.1", port: f.port))
    }

    @Test func stopClosesThePort() throws {
        let f = try Fixture()
        #expect(Self.canConnect(family: AF_INET, address: "127.0.0.1", port: f.port))
        f.stop()
        // Cancelling is asynchronous: give it a moment.
        var open = true
        for _ in 0..<50 where open { usleep(20_000); open = Self.canConnect(family: AF_INET, address: "127.0.0.1", port: f.port) }
        #expect(!open)
    }

    static func canConnect(family: Int32, address: String, port: UInt16) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if family == AF_INET6 {
            var a = sockaddr_in6()
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            inet_pton(AF_INET6, address, &a.sin6_addr)
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            } == 0
        }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr(address)
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    @Test func contentTypes() {
        #expect(LocalFileServer.contentType("m3u8") == "application/vnd.apple.mpegurl")
        #expect(LocalFileServer.contentType("M3U8") == "application/vnd.apple.mpegurl")
        #expect(LocalFileServer.contentType("m4s") == "video/iso.segment")
        #expect(LocalFileServer.contentType("mp4") == "video/mp4")
        #expect(LocalFileServer.contentType("") == "video/mp4")
    }
}
