import Foundation

/// Shared loopback-only fixture process harness. Owns one child and ephemeral port; never probes a live account.
public final class LocalFixtureServer {
    public let process = Process()
    public let scratch: Scratch
    public let base: URL
    public init(script: URL, fixture: URL? = nil, arguments: [String] = []) throws {
        scratch = try Scratch()
        let portFile = scratch.url.appendingPathComponent("port")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--port", "0", "--port-file", portFile.path] + arguments
        if let fixture { process.arguments! += ["--fixture", fixture.path] }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        var readyPort: Int?
        // Creation and publication are separate writes: an existing file can still be empty or incomplete.
        while Date() < deadline, process.isRunning {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text), (1...65535).contains(port) {
                readyPort = port
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let port = readyPort else {
            if process.isRunning { process.terminate() }
            throw URLError(.cannotConnectToHost)
        }
        base = URL(string: "http://127.0.0.1:\(port)")!
    }
    public func stop() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) != 0 { return }
        process.terminate()
        for _ in 0..<200 {
            if waitpid(pid, &status, WNOHANG) != 0 { return }
            usleep(10_000)
        }
        if waitpid(pid, &status, WNOHANG) == 0 { kill(pid, SIGKILL); _ = waitpid(pid, &status, 0) }
    }
    deinit { stop() }
}
