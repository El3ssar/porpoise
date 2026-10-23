import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The bundled fd, run for real on files in a scratch folder (scripts/fetch-search-tools.sh puts them in
/// build/search-tools; CI fetches them too).
private let fetchedTools: FolderSearch.Tools? = {
    let dir = TestPaths.repo
        .appendingPathComponent("build/search-tools")
    let fd = dir.appendingPathComponent("fd").path
    let fm = FileManager.default
    return fm.isExecutableFile(atPath: fd) ? .init(fd: fd) : nil
}()

@MainActor @Suite(.enabled(if: fetchedTools != nil, "needs scripts/fetch-search-tools.sh"))
struct FolderSearchTests {
    let s: Scratch
    let tools = fetchedTools!

    init() throws {
        s = try Scratch("search")
        try s.file("Reports/Q3 Report.pdf", "quarterly")
        try s.file("notes.txt", "the budget is due friday")
        try s.file(".hidden/report-draft.md", "draft")
        try s.file("a+b(1).txt", "x")
        try s.file("line\nbreak report.txt", "x")
        try s.file("other.txt", "nothing")
    }

    /// Runs a search to the end and returns the names found, and how many batches came before the last.
    private func run(_ text: String, contents: Bool = false, limit: Int = 100) async throws -> (
        names: [String], batches: Int, snippets: [String: String]
    ) {
        var result: ([FileItem], [URL: String])?
        var batches = 0
        let search = FolderSearch(spec: try SearchSpec(text, contents: contents), scope: s.url, limit: limit, tools: tools) { items, snippets, done in
            if done { result = (items, snippets) } else { batches += 1 }
        }
        search.start()
        try #require(await eventually { result != nil })
        let (items, snippets) = result ?? ([], [:])
        return (items.map(\.name).sorted(), batches, Dictionary(uniqueKeysWithValues: snippets.map { ($0.key.lastPathComponent, $0.value) }))
    }

    @Test func namesOfFilesAndFoldersInAnyCaseIncludingHiddenOnesAndOddNames() async throws {
        let found = try await run("REPORT")
        #expect(found.names == ["Q3 Report.pdf", "Reports", "line\nbreak report.txt", "report-draft.md"].sorted())
    }

    @Test func theTextIsLiteralNotAPattern() async throws {
        #expect(try await run("+b(1").names == ["a+b(1).txt"])
        #expect(try await run(".*").names.isEmpty)
    }

    /// Searching contents finds files only: a folder whose name matches isn't a result (it has no contents).
    @Test func contentSearchesShowNoFolders() async throws {
        #expect(try await run("report").names.contains("Reports"))
        let found = try await run("report", contents: true).names
        #expect(!found.contains("Reports") && found.contains("Q3 Report.pdf"))
    }

    @Test func contentsAddFilesThatContainTheText() async throws {
        #expect(try await run("budget").names.isEmpty)
        #expect(try await run("budget", contents: true).names == ["notes.txt"])
        // Names still count in a contents search.
        #expect(try await run("other", contents: true).names == ["other.txt"])
    }

    /// A file found by its contents comes with the line it was found in.
    @Test func contentMatchesComeWithTheirLine() async throws {
        try s.file("plan.md", "# Plan\n\n\t  Ask about the BUDGET early  \nbudget again\n")
        let found = try await run("budget", contents: true)
        #expect(found.snippets["plan.md"] == "Ask about the BUDGET early")
        #expect(found.snippets["notes.txt"] == "the budget is due friday")
        // A name that matches too: a name match, no line.
        try s.file("budget-2026.txt", "budget")
        #expect(try await run("budget", contents: true).snippets["budget-2026.txt"] == nil)
    }

    /// Files found elsewhere (Spotlight) get their lines too; files without the text are left out.
    @Test func linesOfGivenFiles() throws {
        let odd = try s.file("we\nird name.txt", "x\n  Budget: tight\n")
        let paths = [s.path("notes.txt").path, s.path("other.txt").path, odd.path, s.path("missing.txt").path]
        let found = FolderSearch.lines(in: paths, spec: try SearchSpec("budget", contents: true))
        #expect(found == [s.path("notes.txt").path: "the budget is due friday", odd.path: "Budget: tight"])
        // Many files: read a few hundred at a time, all of them.
        let many = try (0..<900).map { try s.file("many/f\($0).txt", "has budget \($0)").path }
        #expect(try FolderSearch.lines(in: many, spec: SearchSpec("BUDGET", contents: true)).count == 900)
    }

    @Test func snippetsStartNearTheTextAndStayShort() {
        #expect(FolderSearch.snippet("  a\t\tb  ", around: "b") == "a b")
        let long = String(repeating: "word ", count: 20) + "needle " + String(repeating: "tail ", count: 100)
        let s = FolderSearch.snippet(long, around: "NEEDLE")
        #expect(s.hasPrefix("…") && s.contains("needle") && s.count <= 201)
        #expect(s.distance(from: s.startIndex, to: s.range(of: "needle")!.lowerBound) < 16)
    }

    /// Apps and other packages are single items, as in Finder: found by name, never their insides.
    @Test func packagesAreItemsNotFolders() async throws {
        try s.file("Tool.app/Contents/Info.plist", "x")
        try s.file("Tool.app/Contents/report-inside.txt", "report")
        try s.file("Report Maker.app/Contents/Info.plist", "x")
        let found = try await run("report", contents: true)
        #expect(found.names.contains("Report Maker.app"))
        #expect(!found.names.contains("report-inside.txt"))
    }

    @Test func stopsAtTheLimit() async throws {
        for i in 0..<40 { try s.file("many/match-\(i).txt") }
        #expect(try await run("match-", limit: 10).names.count == 10)
    }

    @Test(arguments: [1, 100]) func completionRemainsTerminalAfterThePendingBatch(_ limit: Int) async throws {
        try s.file("terminal-match.txt")
        var events: [Bool] = []
        var completedNames: [String] = []
        let search = FolderSearch(spec: try SearchSpec("terminal-match", contents: false), scope: s.url, limit: limit, tools: tools) {
            items, _, done in
            events.append(done)
            if done { completedNames = items.map(\.name) }
        }
        defer { search.stop() }
        search.start()
        try #require(await eventually { events.contains(true) })
        // The first batch is delayed 120 ms. Keep observing after completion so it cannot restart progress.
        try await Task.sleep(for: .milliseconds(500))
        #expect(completedNames == ["terminal-match.txt"])
        #expect(events.filter { $0 }.count == 1)
        #expect(events.last == true)
        #expect(!events.drop(while: { !$0 }).dropFirst().contains(false))
    }

    @Test func aFailedToolRetiresItsPendingBatchBeforeFallback() async throws {
        try s.file("terminal-match.txt")
        let tool = try s.file(
            "failed-tool.sh",
            """
            #!/bin/sh
            for search_scope do :; done
            printf '%s\\0' "$search_scope/terminal-match.txt"
            kill -TERM "$$"
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        var events: [String] = []
        let search = FolderSearch(
            spec: try SearchSpec("terminal-match", contents: false), scope: s.url, limit: 100,
            tools: .init(fd: tool.path)
        ) { _, _, done in events.append(done ? "done" : "batch") }
        search.onFailure = { events.append("failure") }
        defer { search.stop() }
        search.start()
        try #require(await eventually { events.contains("failure") })
        try await Task.sleep(for: .milliseconds(500))
        #expect(events.filter { $0 == "failure" }.count == 1)
        #expect(events.last == "failure")
        #expect(!events.drop(while: { $0 != "failure" }).dropFirst().contains("batch"))
        #expect(!events.contains("done"))
    }

    @Test func aStoppedSearchSaysNothingMoreAndLeavesNoTool() async throws {
        for i in 0..<200 { try s.file("deep/\(i)/x/y/match-\(i).txt") }
        var calls = 0
        let search = FolderSearch(spec: try SearchSpec("match", contents: true), scope: s.url, limit: 10_000, tools: tools) { _, _, _ in calls += 1 }
        search.start()
        search.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(calls == 0)
        let left = try? Shell.run("/usr/bin/pgrep", ["-f", s.url.path])
        #expect(left?.status != 0)  // no fd or rg still searching the scratch folder
    }

    @Test func theRunnerUsesTheToolsForAFolder() async throws {
        var result: [FileItem]?
        let runner = SearchRunner(text: "report", scope: s.url, contents: false) { items, done in if done { result = items } }
        runner.folderTools = tools
        runner.start()
        defer { runner.stop() }
        #expect(await eventually { result != nil })
        // The walk would skip nothing either, but only fd finds the name with a line break whole.
        #expect(result?.map(\.name).sorted() == ["Q3 Report.pdf", "Reports", "line\nbreak report.txt", "report-draft.md"].sorted())
    }
}
