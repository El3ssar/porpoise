import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

struct FileNameTests {
    @Test func contextsKeepListingAndProtocolSemanticsSeparate() {
        #expect(FileName.validate("", for: .local) == .empty)
        #expect(FileName.validate("..", for: .local) == .dot)
        #expect(FileName.validate("a/\u{301}b", for: .local) == .separator)
        #expect(FileName.validate("x\0\u{301}", for: .remote) == .nul)
        #expect(FileName.isValid("line\nbreak", for: .local))
        #expect(RemoteParsing.isSafeName("line\nbreak"))
        #expect(FileName.validate("line\r\u{301}break", for: .remote) == .newline)
        #expect(RemoteParsing.localName(forRemote: "line\nbreak") == nil)
        #expect(RemoteParsing.localName(forRemote: "one/two") == "one:two")
        let long = String(repeating: "x", count: 256)
        #expect(FileName.validate(long, for: .local) == .tooLong)
        #expect(FileName.isValid(long, for: .component) && FileName.isValid(long, for: .remote))
        #expect(FileActions.isValidName(long))  // Structural checks also inspect existing APFS names.
        #expect(RemoteParsing.localName(forRemote: long) == nil)
        #expect(FileName.isValid(String(repeating: "é", count: 127) + "x", for: .local))
        #expect(FileName.validate(String(repeating: "é", count: 128), for: .local) == .tooLong)
    }

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
