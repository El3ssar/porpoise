import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite struct VideoSandboxTests {
    @Test func limitsReadsAndWritesAndEscapesPathParameters() throws {
        let scratch = try Scratch()
        let input = try scratch.file("input \" (deny).mkv", "input\n")
        let outside = try scratch.file("private", "private\n")
        let output = try scratch.folder("output")
        try scratch.symlink("output/escape", to: outside.path)
        let canonicalOutput = URL(fileURLWithPath: FilePath.canonical(output.path))
        func run(_ script: String, output: URL?) throws -> Shell.Result {
            try Shell.run(
                "/usr/bin/sandbox-exec",
                VideoPreview.sandboxArguments(
                    executable: "/bin/sh", input: input, output: output,
                    arguments: [
                        "-c", script, "probe", FilePath.canonical(input.path),
                        FilePath.canonical(outside.path), canonicalOutput.appendingPathComponent("result").path,
                        canonicalOutput.appendingPathComponent("escape").path,
                    ]))
        }
        let read = try run("IFS= read -r value < \"$1\" && printf '%s' \"$value\"", output: nil)
        #expect(read.out == Data("input".utf8), "\(read.err)")
        #expect(try run("IFS= read -r value < \"$2\"", output: output).status != 0)
        let write = try run("printf result > \"$3\"", output: output)
        #expect(write.status == 0, "\(write.err)")
        #expect(scratch.read("output/result") == "result")
        #expect(try run("printf forbidden > \"$3\"", output: nil).status != 0)
        #expect(try run("printf forbidden > \"$2\"", output: output).status != 0)
        #expect(try run("printf forbidden > \"$4\"", output: output).status != 0)
        #expect(scratch.read("private") == "private\n")
    }

    @Test func deniesNetwork() throws {
        let scratch = try Scratch()
        let input = try scratch.file("root/input", "input")
        let server = LocalFileServer()
        defer { server.stop() }
        let url = try #require(server.start(root: scratch.path("root"))).appendingPathComponent("input")
        let args = ["--disable", "--noproxy", "*", "--connect-timeout", "2", "--silent", "--show-error", url.absoluteString]
        #expect(try Shell.run("/usr/bin/curl", args).out == Data("input".utf8))
        let result = try Shell.run(
            "/usr/bin/sandbox-exec",
            VideoPreview.sandboxArguments(executable: "/usr/bin/curl", input: input, output: nil, arguments: args))
        #expect(result.status != 0)
        #expect(result.out.isEmpty)
    }
}
