import CryptoKit
import Darwin
import Foundation
import PorpoiseCore

/// A private, same-user Unix socket. This is not an authentication boundary against other processes run by the user.
public enum AutomationSocket {
    public static let maximumRequest = 1024 * 1024
    public static let maximumFrame = 32 * 1024 * 1024
    public static var directory: URL {
        #if PORPOISE_TEST_HOOKS
        if let suite = TestEnvironment.defaultsSuite.value() {
            let hash = SHA256.hash(data: Data(suite.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("pa-\(hash)").path, isDirectory: true)
        }
        #endif
        return FileManager.default.temporaryDirectory.appendingPathComponent("porpoise", isDirectory: true)
    }

    static func secureDirectory(_ directory: URL, create: Bool) throws {
        if create && mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw AutomationError.unsafeEndpoint }
        var info = stat()
        if !create && lstat(directory.path, &info) != 0 && errno == ENOENT { throw AutomationError.unavailable }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
        else { throw AutomationError.unsafeEndpoint }
    }

    static func address(_ directory: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(directory.appendingPathComponent("automation.sock").path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AutomationError.unsafeEndpoint }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func withAddress<T>(_ directory: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = try address(directory)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32) throws {
        guard fd >= 0 else { throw AutomationError.unavailable }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw AutomationError.unavailable }
    }

    static func sameUser(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw AutomationError.unsafeEndpoint }
    }

    static func ready(_ fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AutomationError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 30_000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw result == 0 ? AutomationError.timedOut : AutomationError.unavailable }
            guard descriptor.revents & events != 0 else { throw AutomationError.unavailable }
            return
        }
    }

    static func transfer(_ fd: Int32, bytes: UnsafeMutableRawBufferPointer, writing: Bool, deadline: Date) throws {
        var offset = 0
        while offset < bytes.count {
            try ready(fd, events: Int16(writing ? POLLOUT : POLLIN), deadline: deadline)
            let pointer = bytes.baseAddress!.advanced(by: offset)
            let count = writing ? Darwin.write(fd, pointer, bytes.count - offset) : Darwin.read(fd, pointer, bytes.count - offset)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw AutomationError.unavailable }
            offset += count
        }
    }

    static func readFrame(_ fd: Int32, deadline: Date, maximum: Int = maximumFrame) throws -> Data {
        var header: UInt32 = 0
        try withUnsafeMutableBytes(of: &header) { try transfer(fd, bytes: $0, writing: false, deadline: deadline) }
        let count = Int(UInt32(bigEndian: header))
        guard count > 0, count <= maximum else { throw AutomationError.oversized }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try transfer(fd, bytes: $0, writing: false, deadline: deadline) }
        return data
    }

    static func writeFrame(_ data: Data, fd: Int32, deadline: Date) throws {
        guard !data.isEmpty, data.count <= maximumFrame else { throw AutomationError.oversized }
        var frame = Data()
        var header = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &header) { frame.append(contentsOf: $0) }
        frame.append(data)
        try frame.withUnsafeMutableBytes { try transfer(fd, bytes: $0, writing: true, deadline: deadline) }
    }

    /// Blocking IO: call from a worker, never the app's main thread. Requests are never retried automatically.
    public static func send(_ request: AutomationRequest, directory: URL = directory, timeout: TimeInterval? = nil) throws -> AutomationResponse {
        try request.validate()
        try secureDirectory(directory, create: false)
        var info = stat()
        let path = directory.appendingPathComponent("automation.sock").path
        guard lstat(path, &info) == 0 else { throw AutomationError.unavailable }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            throw AutomationError.unsafeEndpoint
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationError.unavailable }
        defer { close(fd) }
        try configure(fd)
        let deadline = Date().addingTimeInterval(timeout ?? ((request.action == .copy || request.action == .move) ? 120 : 10))
        let result = try withAddress(directory) { connect(fd, $0, $1) }
        if result != 0 {
            guard errno == EINPROGRESS else { throw AutomationError.unavailable }
            try ready(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw AutomationError.unavailable }
        }
        try sameUser(fd)
        let payload = try JSONEncoder().encode(request)
        guard payload.count <= maximumRequest else { throw AutomationError.oversized }
        try writeFrame(payload, fd: fd, deadline: deadline)
        let response = try JSONDecoder().decode(AutomationResponse.self, from: readFrame(fd, deadline: deadline))
        guard response.version == 1, response.id == request.id else { throw AutomationError.invalidResponse }
        return response
    }
}

public final class AutomationServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AutomationRequest, Date) async -> AutomationResponse
    private let source: DispatchSourceRead
    private var lockFD: Int32
    private let directory: URL
    private let state = NSLock()
    private var connections = 0
    private let handler: Handler
    private let requestTimeout: TimeInterval
    private let transferTimeout: TimeInterval
    private let queue = DispatchQueue(label: "app.porpoise.automation", attributes: .concurrent)

    public init(
        directory: URL = AutomationSocket.directory, requestTimeout: TimeInterval = 10, transferTimeout: TimeInterval = 120,
        handler: @escaping Handler
    ) throws {
        try AutomationSocket.secureDirectory(directory, create: true)
        self.directory = directory
        self.handler = handler
        self.requestTimeout = requestTimeout
        self.transferTimeout = transferTimeout
        let lockFD = Darwin.open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw AutomationError.unsafeEndpoint }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_mode & 0o777 == 0o600
        else { close(lockFD); throw AutomationError.unsafeEndpoint }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); throw AutomationError.busy }
        self.lockFD = lockFD
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        do {
            try AutomationSocket.configure(fd)
            let path = directory.appendingPathComponent("automation.sock").path
            // The lifetime lock proves no cooperating live server owns this stale endpoint.
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw AutomationError.unsafeEndpoint }
                guard unlink(path) == 0 else { throw AutomationError.unsafeEndpoint }
            }
            guard try AutomationSocket.withAddress(directory, { bind(fd, $0, $1) }) == 0,
                chmod(path, 0o600) == 0, listen(fd, 8) == 0
            else { throw AutomationError.unavailable }
        } catch {
            if fd >= 0 { close(fd) }
            close(lockFD)
            throw error
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    public func stop() {
        state.lock()
        defer { state.unlock() }
        guard lockFD >= 0 else { return }
        source.cancel()
        unlink(directory.appendingPathComponent("automation.sock").path)
        close(lockFD)
        lockFD = -1
    }
    deinit { stop() }

    private func acceptConnections(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { return }
            state.lock()
            let allowed = connections < 8 && lockFD >= 0
            if allowed { connections += 1 }
            state.unlock()
            guard allowed else { close(fd); continue }
            queue.async { [self] in
                do {
                    try AutomationSocket.configure(fd)
                    try AutomationSocket.sameUser(fd)
                    let deadline = Date().addingTimeInterval(requestTimeout)
                    let request = try JSONDecoder().decode(
                        AutomationRequest.self, from: AutomationSocket.readFrame(fd, deadline: deadline, maximum: AutomationSocket.maximumRequest))
                    try request.validate()
                    let operationDeadline = Date().addingTimeInterval(
                        (request.action == .copy || request.action == .move) ? transferTimeout : requestTimeout)
                    let connection = AutomationConnection(fd)
                    let task = Task { [self] in
                        guard !Task.isCancelled else { return }
                        let response = await self.handler(request, operationDeadline)
                        self.queue.async { [weak self] in
                            if connection.finish(response: try? JSONEncoder().encode(response), deadline: operationDeadline) {
                                self?.releaseConnection()
                            }
                        }
                    }
                    queue.asyncAfter(deadline: .now() + max(0, operationDeadline.timeIntervalSinceNow)) { [weak self] in
                        task.cancel()
                        if connection.finish(deadline: operationDeadline) { self?.releaseConnection() }
                    }
                } catch { finish(fd) }
            }
        }
    }

    private func finish(_ fd: Int32) {
        close(fd)
        releaseConnection()
    }
    private func releaseConnection() {
        state.lock()
        connections -= 1
        state.unlock()
    }
}

/// Serializes response/timeout ownership so a late handler can never write to a recycled descriptor.
private final class AutomationConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    init(_ fd: Int32) { self.fd = fd }
    func finish(response: Data? = nil, deadline: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let fd else { return false }
        if let response { try? AutomationSocket.writeFrame(response, fd: fd, deadline: deadline) }
        close(fd)
        self.fd = nil
        return true
    }
}
