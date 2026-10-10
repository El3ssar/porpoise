import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The bundled fd and ripgrep, run for real on files in a scratch folder (scripts/fetch-search-tools.sh puts them in
/// build/search-tools; CI fetches them too).
private let fetchedTools: FolderSearch.Tools? = {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/search-tools")
    let fd = dir.appendingPathComponent("fd").path, rg = dir.appendingPathComponent("rg").path
    let fm = FileManager.default
    return fm.isExecutableFile(atPath: fd) && fm.isExecutableFile(atPath: rg) ? .init(fd: fd, rg: rg) : nil
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
    private func run(_ text: String, contents: Bool = false, limit: Int = 100) async throws -> (names: [String], batches: Int) {
        var result: [FileItem]?
        var batches = 0
        let search = FolderSearch(text: text, scope: s.url, contents: contents, limit: limit, tools: tools) { items, done in
            if done { result = items } else { batches += 1 }
        }
        search.start()
        try #require(await eventually(10) { result != nil })
        return ((result ?? []).map(\.name).sorted(), batches)
    }

    @Test func namesOfFilesAndFoldersInAnyCaseIncludingHiddenOnesAndOddNames() async throws {
        let found = try await run("REPORT")
        #expect(found.names == ["Q3 Report.pdf", "Reports", "line\nbreak report.txt", "report-draft.md"].sorted())
    }

    @Test func theTextIsLiteralNotAPattern() async throws {
        #expect(try await run("+b(1").names == ["a+b(1).txt"])
        #expect(try await run(".*").names.isEmpty)
    }

    @Test func contentsAddFilesThatContainTheText() async throws {
        #expect(try await run("budget").names.isEmpty)
        #expect(try await run("budget", contents: true).names == ["notes.txt"])
        // Names still count in a contents search.
        #expect(try await run("other", contents: true).names == ["other.txt"])
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

    @Test func aStoppedSearchSaysNothingMoreAndLeavesNoTool() async throws {
        for i in 0..<200 { try s.file("deep/\(i)/x/y/match-\(i).txt") }
        var calls = 0
        let search = FolderSearch(text: "match", scope: s.url, contents: true, limit: 10_000, tools: tools) { _, _ in calls += 1 }
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
        #expect(await eventually(10) { result != nil })
        // The walk would skip nothing either, but only fd finds the name with a line break whole.
        #expect(result?.map(\.name).sorted() == ["Q3 Report.pdf", "Reports", "line\nbreak report.txt", "report-draft.md"].sorted())
    }
}
