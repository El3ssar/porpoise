import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import Testing

@testable import PorpoiseServices

struct GitStatusBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_GIT_BENCHMARK"] == "1"))
    func hundredThousandTrackedFilesAndTenThousandChanges() throws {
        let f = try LocalGitFixture()
        for directory in 0..<100 {
            let folder = try f.scratch.folder("d\(directory)")
            for file in 0..<1000 {
                guard FileManager.default.createFile(atPath: folder.appendingPathComponent("f\(file)").path, contents: Data()) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
        try f.record()
        func measure(_ name: String, count: Int) throws {
            for run in 1...5 {
                let start = ProcessInfo.processInfo.systemUptime
                let data = try GitCommand.run(
                    ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"],
                    in: f.url, deadline: start + GitStatusService.budget)
                let command = ProcessInfo.processInfo.systemUptime - start
                let snapshot = try GitStatusParser.parse(data)
                let total = ProcessInfo.processInfo.systemUptime - start
                #expect(snapshot.files.count == count)
                print(
                    "GIT_BENCH \(name) run=\(run) command_ms=\(command * 1000) total_ms=\(total * 1000) bytes=\(data.count) entries=\(snapshot.files.count)"
                )
            }
        }
        try measure("100k-clean", count: 0)
        for directory in 0..<10 {
            for file in 0..<1000 { try Data("changed".utf8).write(to: f.scratch.path("d\(directory)/f\(file)")) }
        }
        try measure("10k-changed", count: 10_000)
    }
}
