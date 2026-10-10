import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Running tools: exit status, both outputs, stdin, files, timeouts, and no deadlock on large outputs.
@Suite struct ShellTests {
    @Test func exitStatusAndBothOutputs() throws {
        let r = try Shell.run("/bin/sh", ["-c", "printf out; printf err >&2; exit 3"])
        #expect(r.status == 3)
        #expect(String(decoding: r.out, as: UTF8.self) == "out")
        #expect(r.err == "err")
        #expect(try Shell.run("/usr/bin/true", []).status == 0)
    }

    @Test func argumentsAreNeverParsedByAShell() throws {
        let hostile = ["$(echo pwned)", "a b", "`id`", "x;y", "*", "'\"", "new\nline", ""]
        let r = try Shell.run("/usr/bin/printf", ["%s\\0"] + hostile)
        #expect(
            String(decoding: r.out, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) == hostile)
    }

    @Test func environmentIsAddedToTheInheritedOne() throws {
        let r = try Shell.run("/bin/sh", ["-c", "printf '%s|%s' \"$PORPOISE_T\" \"${PATH:+set}\""], env: ["PORPOISE_T": "v a l"])
        #expect(String(decoding: r.out, as: UTF8.self) == "v a l|set")
    }

    @Test func largeOutputsOnBothPipesDoNotDeadlock() throws {
        // 4 MB on each pipe, written interleaved: far more than a pipe buffer holds.
        let script = "i=0; while [ $i -lt 64 ]; do head -c 65536 /dev/zero; head -c 65536 /dev/zero >&2; i=$((i+1)); done"
        let r = try Shell.run("/bin/sh", ["-c", script], timeout: 30)
        #expect(r.status == 0)
        #expect(r.out.count == 64 * 65536)
        #expect(r.err.utf8.count == 64 * 65536)
    }

    @Test func largeStdinIsWrittenWhileOutputIsRead() throws {
        var data = Data(count: 8 << 20)
        data.withUnsafeMutableBytes { b in for i in stride(from: 0, to: b.count, by: 4096) { b[i] = UInt8(i / 4096 % 251) } }
        let r = try Shell.run("/bin/cat", [], stdin: data, timeout: 30)
        #expect(r.out == data)
    }

    @Test func aToolThatIgnoresItsStdinDoesNotKillUs() throws {
        // Exits at once while megabytes are still to be written: SIGPIPE must not reach this process.
        let r = try Shell.run("/usr/bin/true", [], stdin: Data(count: 16 << 20), timeout: 30)
        #expect(r.status == 0)
    }

    @Test func withoutStdinTheToolReadsNothing() throws {
        let r = try Shell.run("/bin/cat", [], timeout: 10)
        #expect(r.out.isEmpty && r.status == 0)
    }

    @Test func stdinAndStdoutFiles() throws {
        let s = try Scratch()
        let input = try s.file("in.txt", String(repeating: "line\n", count: 100_000))
        let output = s.path("out.txt")
        let r = try Shell.run("/usr/bin/sort", ["-r"], stdoutFile: output, stdinFile: input)
        #expect(r.status == 0)
        #expect(r.out.isEmpty)
        #expect(s.read("out.txt") == String(repeating: "line\n", count: 100_000))
        // An existing stdout file is replaced, not appended to.
        try Shell.run("/bin/echo", ["x"], stdoutFile: output)
        #expect(s.read("out.txt") == "x\n")
    }

    @Test func unwritableStdoutFileOrMissingStdinFileThrows() throws {
        let s = try Scratch()
        #expect(throws: (any Error).self) { try Shell.run("/bin/echo", [], stdoutFile: s.path("missing/folder/out")) }
        #expect(throws: (any Error).self) { try Shell.run("/bin/cat", [], stdinFile: s.path("missing")) }
    }

    @Test func missingToolThrows() {
        #expect(throws: (any Error).self) { try Shell.run("/nonexistent/tool", []) }
    }

    @Test func timeoutTerminatesAndThrows() {
        let start = Date()
        #expect(throws: RemoteError.self) { try Shell.run("/bin/sleep", ["30"], timeout: 0.3) }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func timeoutKillsAToolThatIgnoresTerminate() {
        let start = Date()
        // `exec` keeps one process (no child holding the pipes); SIGTERM is ignored, so only the SIGKILL ends it.
        #expect(throws: RemoteError.self) { try Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.05; done"], timeout: 0.3) }
        let took = Date().timeIntervalSince(start)
        #expect(took >= 2 && took < 8, "\(took)")
    }

    @Test func aFastToolIsNotHitByItsTimeout() throws {
        let r = try Shell.run("/bin/echo", ["ok"], timeout: 5)
        #expect(String(decoding: r.out, as: UTF8.self) == "ok\n")
    }

    @Test func whichFindsToolsInTheUsualPlaces() {
        #expect(Shell.which("ls").map { $0.hasSuffix("/ls") } == true)
        #expect(Shell.which("porpoise-no-such-tool-\(UUID().uuidString)") == nil)
    }
}
