import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

struct LocalFileNameTests {
    @Test func nestedPathsAndWarningsDoNotBypassErrors() throws {
        #expect(FileName.validate("a//b", for: .multiComponent) == .nestedFolders)
        #expect(FileName.validate("a/../b", for: .multiComponent) == .dot)
        #expect(FileName.validate("/outside", for: .multiComponent) == .separator)
        #expect(FileName.validate("/\u{301}outside", for: .multiComponent) == .separator)
        #expect(FileName.validate(".hidden/" + String(repeating: "x", count: 256), for: .multiComponent) == .tooLong)
        #expect(FileName.validate(".hidden", for: .local) == .hidden)
        #expect(FileName.validate(".\u{301}hidden", for: .local) == .hidden)
        #expect(FileName.validate(" x ", for: .local) == .whitespace)
        #expect(FileName.isValid(".hidden", for: .local) && FileName.isValid(" x ", for: .local))
        let scratch = try Scratch()
        let nested = try FileActions.makeFolder(named: "a/b", in: scratch.url)
        #expect(FileManager.default.fileExists(atPath: nested.path))
        for invalid in ["", "../escape", "bad\0name", String(repeating: "x", count: 256)] {
            #expect(throws: (any Error).self) { try FileActions.makeFile(named: invalid, in: scratch.url) }
            #expect(throws: (any Error).self) { try FileActions.makeFolder(named: invalid, in: scratch.url) }
            #expect(FileActions.validateName(invalid, in: scratch.url, allowSlash: false)?.isError == true)
        }
        let dangling = scratch.url.appendingPathComponent("taken")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/missing/target")
        #expect(FileActions.validateName("taken", in: scratch.url, allowSlash: false)?.isError == true)
        #expect(FileActions.validateName("   ", in: scratch.url, allowSlash: false)?.isError == true)
        #expect(FileActions.validateName(".hidden", in: scratch.url, allowSlash: false)?.isError == false)
        for problem: FileName.NameProblem in [.empty, .dot, .separator, .nul, .newline, .tooLong, .hidden, .whitespace, .nestedFolders] {
            #expect(problem.message(for: "name").isEmpty == (problem == .empty))
        }
    }
}
