import Foundation
import Testing

@testable import PorpoiseCore

struct GitStatusTests {
    private func parse(_ records: [String]) throws -> GitStatusSnapshot {
        try GitStatusParser.parse(Data((records.joined(separator: "\0") + "\0").utf8))
    }
    @Test func everyStatusAndPathGrammar() throws {
        let s = try parse([
            "# branch.head feature/test", "# branch.oid abcdef012345", "# branch.ab +12 -3",
            "1 .M N... 100644 100644 100644 a b folder/é 'quotes'\nline.txt",
            "1 A. N... 000000 100644 100644 a b added", "? untracked/space name",
            "u UU N... 100644 100644 100644 100644 a b c conflict",
            "2 R. N... 100644 100644 100644 a b R100 new/renamed", "old/name",
            "1 .D N... 100644 100644 000000 a b deleted", "! ignored/",
        ])
        #expect(s.branchText == "⎇ feature/test ↑12 ↓3")
        #expect(s.files["folder/é 'quotes'\nline.txt"] == .modified)
        #expect(s.files["added"] == .added && s.files["untracked/space name"] == .untracked)
        #expect(s.files["conflict"] == .conflicted && s.files["new/renamed"] == .renamed)
        #expect(s.files["deleted"] == .deleted)
        #expect(s.originalPaths["new/renamed"] == "old/name")
        #expect(s.status(for: "new", directory: true) == .changedFolder)
        #expect(s.status(for: "old", directory: true) == .changedFolder)
        #expect(s.status(for: "ignored/deep/file", directory: false) == .ignored)
        #expect(s.status(for: "ignore", directory: true) == nil)
    }
    @Test func cleanUnbornAndDetachedBranches() throws {
        #expect(try parse(["# branch.oid (initial)", "# branch.head main"]).branchText == "⎇ main")
        #expect(try parse(["# branch.oid abcdef123456", "# branch.head (detached)"]).branchText == "⎇ Detached abcdef12")
        #expect(try GitStatusParser.parse(Data()).files.isEmpty)
    }
    @Test func malformedTruncatedAndEscapingPathsAreRejected() {
        for text in [
            "? ../escape\0", "? /absolute\0", "? a/../b\0", "? a//b\0", "? a/./b\0", "? \0", "? truncated", "u UU\0",
            "2 R. N... 1 1 1 a b R100 new\0", "# branch.ab +bad -2\0",
        ] {
            #expect(throws: GitStatusParser.Invalid.self) { try GitStatusParser.parse(Data(text.utf8)) }
        }
        #expect(throws: GitStatusParser.Invalid.self) { try GitStatusParser.parse(Data([63, 32, 255, 0])) }
    }
    @Test func renamesConsumeExactlyOneOriginalRecord() throws {
        let s = try parse(["2 R. N... 1 1 1 a b R100 next", "? original name\n", "? real untracked"])
        #expect(s.files.count == 2)
        #expect(s.originalPaths["next"] == "? original name\n")
        #expect(s.files["real untracked"] == .untracked)
    }
    @Test func foldersOnlyReflectChangedDescendants() throws {
        let s = try parse(["? a/b/c/file", "! ignored/cache/"])
        #expect(s.changedFolders == ["a", "a/b", "a/b/c"])
        #expect(s.status(for: "a/b", directory: false) == nil)
        #expect(s.status(for: "ignored", directory: true) == nil)
    }
}
