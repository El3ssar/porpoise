import Foundation
import PorpoiseServices
import PorpoiseTestSupport

/// Local Git objects only; commit-tree writes fixture history without running commit hooks.
public final class LocalGitFixture: @unchecked Sendable {
    public let scratch: Scratch
    public var url: URL { scratch.url }
    public init() throws {
        scratch = try Scratch()
        _ = try git(["init", "-b", "main"])
    }
    @discardableResult public func git(_ args: [String], stdin: Data? = nil) throws -> Data {
        let result = try Shell.run(
            "/usr/bin/git", ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-C", url.path] + args,
            env: [
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
                "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_NAME": "Fixture",
                "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            ], stdin: stdin, timeout: 30)
        guard result.status == 0 else { throw CocoaError(.fileReadUnknown) }
        return result.out
    }
    public func record() throws {
        try git(["add", "-A"])
        let tree = String(decoding: try git(["write-tree"]), as: UTF8.self).trimmingCharacters(in: .newlines)
        let commit = String(decoding: try git(["commit-tree", tree, "-m", "Fixture"]), as: UTF8.self).trimmingCharacters(in: .newlines)
        try git(["update-ref", "refs/heads/main", commit])
    }
}
