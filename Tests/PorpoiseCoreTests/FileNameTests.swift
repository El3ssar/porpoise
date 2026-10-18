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

}
