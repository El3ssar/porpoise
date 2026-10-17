import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Explicit, real-filesystem benchmarks. Never runs as part of the ordinary suite.
@MainActor
@Suite(
    .serialized, .isolatedSettings, .sshServer,
    .enabled(if: ProcessInfo.processInfo.environment["TRANSFER_BENCH"] == "1", "opt-in transfer benchmark"))
struct TransferBenchmarks {
    struct Measurement: Codable {
        var fixture: String
        var tool: String
        var seconds: Double
        var bytes: Int64
        var files: Int
        var error: String?
        var extraEntries: [String] = []
        var missingEntries: [String] = []
    }

    @Test func copyMatrix() async throws {
        let s = try Scratch("transfer-benchmark")
        let fm = FileManager.default
        let output = ProcessInfo.processInfo.environment["TRANSFER_BENCH_OUTPUT"].map { URL(fileURLWithPath: $0) }
        var measurements: [Measurement] = []
        func record(_ measurement: Measurement) throws {
            measurements.append(measurement)
            print("TRANSFER_BENCH \(measurement.fixture) | \(measurement.tool) | \(measurement.seconds)s | \(measurement.error ?? "ok")")
            if let output { try JSONEncoder().encode(measurements).write(to: output, options: .atomic) }
        }
        let small = try s.folder("small")
        let block = Data(repeating: 0x53, count: 4096)
        for index in 0..<10_000 { try block.write(to: small.appendingPathComponent(String(format: "file-%05d.dat", index))) }
        let large = try s.folder("large")
        let largeFile = large.appendingPathComponent("ten-gigabytes.bin")
        fm.createFile(atPath: largeFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: largeFile)
        let chunk = Data(repeating: 0x39, count: 4 << 20)
        var remaining: Int64 = 10_000_000_000
        while remaining > 0 {
            let count = Int(min(remaining, Int64(chunk.count)))
            try handle.write(contentsOf: chunk.prefix(count))
            remaining -= Int64(count)
        }
        try handle.synchronize(); try handle.close()
        var info = stat(); #expect(lstat(largeFile.path, &info) == 0)
        print("TRANSFER_BENCH source logical=\(info.st_size) allocated=\(Int64(info.st_blocks) * 512)")
        let image = try DiskImage(name: "TransferBench", megabytes: 14_000, in: s)
        for (fixture, bytes, count) in [(small, Int64(40_960_000), 10_000), (large, Int64(10_000_000_000), 1)] {
            let sources = try fm.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
            for (location, parent) in [("same-volume", s.url), ("disk-image", image.volume)] {
                let requestedTools = ProcessInfo.processInfo.environment["TRANSFER_BENCH_TOOLS"]?.components(separatedBy: ",")
                for tool in requestedTools ?? ["Porpoise", "Porpoise (stream)", "cp", "Finder"] {
                    let destination = parent.appendingPathComponent("out-" + UUID().uuidString)
                    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                    let started = ProcessInfo.processInfo.systemUptime
                    var failure: String?
                    do {
                        if tool.hasPrefix("Porpoise") {
                            let c = makeController(ScriptedUI())
                            c.journals = JournalStore(folder: s.path("journals-" + UUID().uuidString))
                            c.history = OperationHistory(file: s.path("history-" + UUID().uuidString))
                            c.prepareJob = { $0.allowsClone = tool == "Porpoise" }
                            let result = await c.perform(.copy, sources, to: destination)
                            guard result.count == sources.count, c.activities.last?.errors.isEmpty == true else {
                                throw CocoaError(.fileWriteUnknown)
                            }
                        } else if tool == "cp" {
                            let result = try Shell.run("/bin/cp", ["-Rp", fixture.path + "/.", destination.path], timeout: 180)
                            if result.status != 0 { throw RemoteError.failed(result.err) }
                        } else {
                            // All paths are generated scratch paths. AppleScript receives them as literal strings.
                            func quoted(_ path: String) -> String {
                                "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                            }
                            let script = """
                                with timeout of 180 seconds
                                    tell application "Finder"
                                        set sourceFolder to POSIX file \(quoted(fixture.path)) as alias
                                        set destinationFolder to POSIX file \(quoted(destination.path)) as alias
                                        duplicate every item of sourceFolder to destinationFolder
                                    end tell
                                end timeout
                                """
                            let result = try Shell.run("/usr/bin/osascript", ["-e", script], timeout: 190)
                            if result.status != 0 { throw RemoteError.failed(result.err) }
                        }
                    } catch { failure = error.localizedDescription }
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    var extras: [String] = [], missing: [String] = []
                    if failure == nil {
                        let expected = Set(sources.map(\.lastPathComponent))
                        let actual = Set(try fm.contentsOfDirectory(atPath: destination.path))
                        extras = actual.subtracting(expected).sorted()
                        missing = expected.subtracting(actual).sorted()
                        let unexpected = extras.filter { $0 != ".DS_Store" }
                        if !missing.isEmpty || !unexpected.isEmpty {
                            failure = "File verification failed: missing \(missing.count), unexpected \(unexpected.count)"
                        }
                        #expect(missing.isEmpty && unexpected.isEmpty)
                        if count == 1 {
                            let copied = destination.appendingPathComponent(largeFile.lastPathComponent)
                            #expect((try fm.attributesOfItem(atPath: copied.path)[.size] as? NSNumber)?.int64Value == bytes)
                            let check = try FileHandle(forReadingFrom: copied)
                            #expect(try check.read(upToCount: 4096) == Data(repeating: 0x39, count: 4096))
                            try check.seek(toOffset: UInt64(bytes - 4096))
                            #expect(try check.read(upToCount: 4096) == Data(repeating: 0x39, count: 4096))
                            try check.close()
                        }
                    }
                    try record(
                        .init(
                            fixture: fixture.lastPathComponent + " " + location, tool: tool, seconds: elapsed, bytes: bytes, files: count,
                            error: failure))
                    try fm.removeItem(at: destination)
                }
            }
        }
        if ProcessInfo.processInfo.environment["TRANSFER_BENCH_TOOLS"] == nil, let server = SSHServer.current {
            let destination = try server.folder()
            let provider = server.provider()
            RemoteFS.use(provider, for: server.url("/"))
            defer { RemoteFS.use(nil, for: server.url("/")) }
            let c = makeController(ScriptedUI())
            c.journals = JournalStore(folder: s.path("remote-journals"))
            c.history = OperationHistory(file: s.path("remote-history"))
            let started = ProcessInfo.processInfo.systemUptime
            _ = await c.perform(.copy, [largeFile], to: server.url(destination.path, isDirectory: true))
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let error = c.activities.last?.errors.first
            try record(.init(fixture: "large loopback SSH", tool: "Porpoise", seconds: elapsed, bytes: 10_000_000_000, files: 1, error: error))
        }
    }
}
