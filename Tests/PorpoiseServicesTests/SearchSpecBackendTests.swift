import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor struct SearchSpecBackendTests {
    @Test func indexedToolAndWalkSearchesHonorTheSameQueryAndFolding() async throws {
        let s = try Scratch(), defaults = SearchIndexCoverageTests.Defaults(), root = try s.folder("root")
        try s.file("root/Reports/Café Annual.PDF", "a report")
        try s.file("root/Reports/Cafe annual.txt", "budget résumé")
        try s.file("root/Reports/tea.pdf", "tea")
        let old = try s.file("root/Reports/old.pdf", "old")
        try s.file("root/.hidden/cafe.pdf", "hidden")
        try s.folder("root/Folder café")
        try s.folder("root/Café.PDF")
        try s.symlink("root/link café", to: "Folder café")
        try s.file("root/content.txt", "CAFÉ inside\next:pdf is literal\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: old.path)
        let index = SearchIndex(directory: s.path("index"), defaults: defaults.store)
        var config = IndexConfiguration(); config.enabled = true; config.content = true; config.roots = [root.path]
        index.configure(config)
        defer { index.configure(IndexConfiguration()) }
        await expectEventually(timeout: 30) { !index.status.building && index.status.updated != nil }
        let toolsDirectory = TestPaths.repo.appendingPathComponent("build/search-tools")
        let tools = FolderSearch.Tools(fd: toolsDirectory.appendingPathComponent("fd").path)
        try #require(FileManager.default.isExecutableFile(atPath: tools.fd), "fetch-search-tools.sh is required")
        let cases: [(String, Bool, Set<String>)] = [
            ("ext:pdf", false, ["Café Annual.PDF", "tea.pdf", "old.pdf", "cafe.pdf"]),
            ("CAFÉ annual ext:pdf", false, ["Café Annual.PDF"]),
            ("path:Reports size:>5 file: dm:>=2026-01-01", false, ["Café Annual.PDF", "Cafe annual.txt"]),
            ("folder: café", false, ["Folder café", "Café.PDF"]),
            ("folder: size:0", false, ["Folder café", "Café.PDF", "Reports", ".hidden"]),
            ("file: regex:^link", false, ["link café"]),
            ("file: regex:^link size:>0", false, ["link café"]),
            ("regex:^caf ext:txt", false, ["Cafe annual.txt"]),
            ("\"cafe annual\" ext:pdf", false, ["Café Annual.PDF"]),
            ("café", true, ["Café Annual.PDF", "Cafe annual.txt", "cafe.pdf", "content.txt"]),
            ("ext:pdf", true, ["content.txt"]),
        ]
        for (text, contents, expected) in cases {
            for backend in 0..<3 {
                var result: [FileItem]?
                let runner = SearchRunner(text: text, scope: root, contents: contents) { items, done in if done { result = items } }
                runner.index = index; runner.usesIndex = backend == 0; runner.usesSpotlight = false
                runner.folderTools = backend == 1 ? tools : nil
                runner.start()
                await expectEventually(timeout: 30) { result != nil }
                #expect(Set(result?.map(\.name) ?? []) == expected, "query=\(text), contents=\(contents), backend=\(backend)")
                #expect(runner.queryError == nil)
                if contents, text == "café" {
                    #expect(
                        runner.snippets[URL(fileURLWithPath: FilePath.canonical(root.appendingPathComponent("content.txt").path))] == "CAFÉ inside")
                }
                runner.stop()
            }
        }
        for backend in 0..<3 {
            var done = false
            let invalid = SearchRunner(text: "ext:", scope: root, contents: false) { items, finished in
                #expect(items.isEmpty); done = finished
            }
            invalid.index = index; invalid.usesIndex = backend == 0; invalid.usesSpotlight = false; invalid.folderTools = backend == 1 ? tools : nil
            invalid.start()
            #expect(done && invalid.queryError == "Invalid search: ext:")
            invalid.stop()
        }
    }
}
