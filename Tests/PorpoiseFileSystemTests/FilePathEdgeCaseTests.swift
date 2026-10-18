import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct FilePathEdgeCaseTests {
    @Test func entryAndCanonicalEdgeCases() {
        #expect(FilePath.entry("/") == "/")
        #expect(FilePath.entry("/top-level-entry") == "/top-level-entry")
        let tmp = FilePath.canonical(NSTemporaryDirectory())
        #expect(FilePath.entry(NSTemporaryDirectory() + "leaf/") == tmp + "/leaf")
        // A missing top-level folder keeps its spelling below the root.
        let missing = "/porpoise-missing-\(UUID().uuidString)"
        #expect(FilePath.canonical(missing + "/child") == missing + "/child")
        // Relative paths are taken from the current directory.
        let cwd = FilePath.canonical(FileManager.default.currentDirectoryPath)
        #expect(FilePath.canonical("porpoise-relative-\(missing.dropFirst())") == cwd + "/porpoise-relative-\(missing.dropFirst())")
    }
}
