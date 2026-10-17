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
        while !FileManager.default.fileExists(atPath: portFile.path), Date() < deadline, process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        guard let port = try? String(contentsOf: portFile, encoding: .utf8), Int(port) != nil else {
            process.terminate(); throw URLError(.cannotConnectToHost)
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
