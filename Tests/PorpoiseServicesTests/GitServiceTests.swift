import Darwin
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized, .isolatedSettings) struct GitCommandTests {
    @Test func realStatusIsReadOnlyAndDoesNotRunFSMonitor() throws {
        let f = try LocalGitFixture()
        try f.scratch.file("é 'quoted'\n.txt", "before")
        try f.scratch.file(".gitignore", "ignored/\n")
        try f.record()
        let index = try Data(contentsOf: f.scratch.path(".git/index"))
        try f.scratch.file("é 'quoted'\n.txt", "after")
        try f.scratch.file("ignored/cache", "ignored")
        try f.scratch.file("new/f", "new")
        let hook = try f.scratch.file("monitor", "#!/bin/sh\ntouch '\(f.scratch.path("BAD").path)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try f.git(["config", "core.fsmonitor", hook.path])
        let result = try GitStatusParser.parse(
            GitCommand.run(
                ["status", "--porcelain=v2", "-z", "--branch", "--ignored=matching", "-uall"], in: f.url,
                deadline: ProcessInfo.processInfo.systemUptime + 2))
        #expect(result.branch == "main")
        #expect(result.files["é 'quoted'\n.txt"] == .modified)
        #expect(result.files["new/f"] == .untracked)
        #expect(result.files["ignored"] == .ignored)
        #expect(!FileManager.default.fileExists(atPath: f.scratch.path("BAD").path))
        #expect(!FileManager.default.fileExists(atPath: f.scratch.path(".git/index.lock").path))
        #expect(try Data(contentsOf: f.scratch.path(".git/index")) == index)
    }
    @Test func deadlineKillsTheEntireProcessGroup() throws {
        let scratch = try Scratch()
        let marker = scratch.path("pid")
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: GitCommand.Failure.self) {
            try GitCommand.runProcess(
                "/bin/sh", ["-c", "trap '' TERM; /bin/sleep 30 & echo $! > \"$1\"; wait", "fixture", marker.path],
                in: scratch.url, environment: GitCommand.environment, deadline: start + 0.2, limit: 1024)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
        let child = try #require(scratch.read("pid").flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let until = ProcessInfo.processInfo.systemUptime + 2
        while kill(child, 0) == 0 && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.01) }
        #expect(kill(child, 0) != 0)
    }

    @Test func outputAndTimeBudgetsGiveUp() throws {
        let f = try LocalGitFixture()
        try f.scratch.file("untracked", "text")
        #expect(throws: GitCommand.Failure.self) {
            try GitCommand.run(["status", "--porcelain=v2", "-z"], in: f.url, deadline: ProcessInfo.processInfo.systemUptime + 2, limit: 2)
        }
        #expect(throws: GitCommand.Failure.self) { try GitCommand.run(["status"], in: f.url, deadline: ProcessInfo.processInfo.systemUptime - 1) }
        #expect(GitCommand.environment["GIT_NO_LAZY_FETCH"] == "1")
        #expect(GitCommand.environment["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(GitCommand.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(try GitCommand.path(Data("/tmp/new\nline \n".utf8)).path == "/tmp/new\nline ")
    }
}

@Suite(.serialized, .isolatedSettings) @MainActor struct GitServiceTests {
    private final class State { var value: GitFolderStatus?; var deliveries = 0 }
    @Test func cachedStateRefreshesForDeepChangesAndGitEvents() async throws {
        let f = try await Task.detached {
            let f = try LocalGitFixture(); try f.scratch.file("deep/child/file", "before"); try f.record(); return f
        }.value
        let state = State()
        let token = GitStatusService.shared.observe(f.url) {
            state.value = $0; state.deliveries += 1
        }
        defer { token.cancel() }
        try #require(await eventually { state.value?.snapshot.branch == "main" })
        #expect(state.value?.snapshot.files.isEmpty == true)
        let second = State()
        let other = GitStatusService.shared.observe(f.url) { second.value = $0 }
        defer { other.cancel() }
        try #require(await eventually { second.value != nil })
        try f.scratch.file("deep/child/file", "after")
        try #require(await eventually(10) { state.value?.snapshot.files["deep/child/file"] == .modified })
        #expect(state.value?.snapshot.status(for: "deep", directory: true) == .changedFolder)
        try #require(await eventually { second.value?.snapshot.files["deep/child/file"] == .modified })
        try await Task.detached { try f.git(["symbolic-ref", "HEAD", "refs/heads/other"]) }.value
        try #require(await eventually(10) { state.value?.snapshot.branch == "other" })
        token.cancel()
        let deliveries = state.deliveries
        try f.scratch.file("another", "change")
        try #require(await eventually(10) { second.value?.snapshot.files["another"] == .untracked })
        #expect(state.deliveries == deliveries)
    }
    @Test func worktreesDetachedHeadSymlinkedFoldersAndBareRepositories() async throws {
        let f = try await Task.detached {
            let f = try LocalGitFixture(); try f.scratch.file("file", "before"); try f.record()
            try f.git(["worktree", "add", "--detach", f.scratch.path("worktree").path, "HEAD"])
            try f.scratch.file("worktree/file", "after")
            try f.scratch.symlink("alias", to: f.scratch.path("worktree").path)
            try f.git(["init", "--bare", f.scratch.path("bare").path]); return f
        }.value
        let state = State()
        let token = GitStatusService.shared.observe(f.scratch.path("alias")) {
            state.value = $0; state.deliveries += 1
        }
        defer { token.cancel() }
        try #require(await eventually { state.value != nil })
        #expect(state.value?.snapshot.branch == "(detached)")
        let item = FileItem(url: f.scratch.path("alias/file"), name: "file", isDirectory: false)
        #expect(state.value?.status(for: item) == .modified)
        #expect(state.value?.relativePath(for: URL(string: "sftp://server/file")!) == nil)
        let bare = State()
        let bareToken = GitStatusService.shared.observe(f.scratch.path("bare")) {
            bare.value = $0; bare.deliveries += 1
        }
        defer { bareToken.cancel() }
        try #require(await eventually { bare.deliveries > 0 })
        #expect(bare.value == nil)
    }
    @Test func submoduleDirtyDotAndLocalAheadBehindWithoutNetwork() async throws {
        let f = try await Task.detached {
            let f = try LocalGitFixture()
            let sub = try f.scratch.folder("sub")
            try f.git(["-C", sub.path, "init", "-b", "main"])
            try f.scratch.file("sub/file", "before")
            try f.git(["-C", sub.path, "add", "file"])
            let tree = String(decoding: try f.git(["-C", sub.path, "write-tree"]), as: UTF8.self).trimmingCharacters(in: .newlines)
            let commit = String(decoding: try f.git(["-C", sub.path, "commit-tree", tree, "-m", "Fixture"]), as: UTF8.self).trimmingCharacters(
                in: .newlines)
            try f.git(["-C", sub.path, "update-ref", "refs/heads/main", commit])
            try f.record()
            let base = String(decoding: try f.git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .newlines)
            try f.git(["update-ref", "refs/remotes/origin/main", base])
            try f.git(["config", "remote.origin.url", "https://must-never-connect.invalid/repo"])
            try f.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
            try f.git(["config", "branch.main.remote", "origin"])
            try f.git(["config", "branch.main.merge", "refs/heads/main"])
            let parentTree = String(decoding: try f.git(["write-tree"]), as: UTF8.self).trimmingCharacters(in: .newlines)
            let next = String(decoding: try f.git(["commit-tree", parentTree, "-p", base, "-m", "Next"]), as: UTF8.self).trimmingCharacters(
                in: .newlines)
            let other = String(decoding: try f.git(["commit-tree", parentTree, "-p", base, "-m", "Other"]), as: UTF8.self).trimmingCharacters(
                in: .newlines)
            try f.git(["update-ref", "refs/heads/main", next]); try f.git(["update-ref", "refs/remotes/origin/main", other])
            try f.scratch.file("sub/file", "after")
            // A normal submodule uses a .git pointer, not an embedded .git directory.
            try f.scratch.file(".gitmodules", "[submodule \"sub\"]\n    path = sub\n    url = https://must-never-connect.invalid/sub\n")
            try f.git(["submodule", "absorbgitdirs", "sub"])
            return f
        }.value
        let parent = State(), child = State()
        let a = GitStatusService.shared.observe(f.url) { parent.value = $0 }
        let b = GitStatusService.shared.observe(f.scratch.path("sub")) { child.value = $0 }
        defer { a.cancel(); b.cancel() }
        try #require(await eventually { parent.value != nil && child.value != nil })
        #expect(parent.value?.snapshot.ahead == 1 && parent.value?.snapshot.behind == 1)
        #expect(parent.value?.snapshot.status(for: "sub", directory: true) == .changedFolder)
        #expect(child.value?.snapshot.files["file"] == .modified)
    }

    @Test func comparisonCopiesHeadAndWorkingFileAndCleansUp() async throws {
        let f = try await Task.detached {
            let f = try LocalGitFixture(); try f.scratch.file("é\nfile.txt", "before\n"); try f.record()
            try f.scratch.file("é\nfile.txt", "after\n"); return f
        }.value
        let state = State()
        let token = GitStatusService.shared.observe(f.url) { state.value = $0 }
        defer { token.cancel() }
        try #require(await eventually { state.value != nil })
        let status = try #require(state.value)
        let item = FileItem(url: f.scratch.path("é\nfile.txt"), name: "é\nfile.txt", isDirectory: false)
        var comparison: GitComparison? = try await Task.detached { try GitComparison(item: item, status: status) }.value
        let left = try #require(comparison?.left), right = try #require(comparison?.right)
        #expect(try String(contentsOf: left, encoding: .utf8) == "before\n")
        #expect(try String(contentsOf: right, encoding: .utf8) == "after\n")
        #expect(f.scratch.read("é\nfile.txt") == "after\n")
        comparison = nil
        #expect(!FileManager.default.fileExists(atPath: left.path))
    }
}
