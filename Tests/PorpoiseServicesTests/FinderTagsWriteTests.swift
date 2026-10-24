import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct FinderTagsWriteTests {
    @Test func writeFailureThrowsAndSuccessfulSiblingsKeepTheirTags() throws {
        let s = try Scratch(), file = try s.file("file.txt"), missing = s.path("missing/file.txt")
        #expect(throws: (any Error).self) { try FinderTags.set(["Red"], on: missing) }
        let failures = FinderTags.toggle("Red", on: [file, missing])
        #expect(failures.map(\.url) == [missing])
        #expect(try file.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Red"])
        #expect(FinderTags.toggle("Red", on: [file]).isEmpty)
        #expect(try file.resourceValues(forKeys: [.tagNamesKey]).tagNames?.isEmpty != false)
    }
}
