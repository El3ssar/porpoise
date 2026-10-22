import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

@Suite struct AccessSummaryTests {
    @Test func everyCombinationHasFindersWords() {
        #expect(AccessSummary.text(readable: true, writable: true) == "Read & Write")
        #expect(AccessSummary.text(readable: true, writable: false) == "Read Only")
        #expect(AccessSummary.text(readable: false, writable: true) == "Write Only (Drop Box)")
        #expect(AccessSummary.text(readable: false, writable: false) == "No Access")
    }

    @Test func aLocalFileIsAskedForThisUser() throws {
        let s = try Scratch()
        let file = try s.file("note.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(AccessSummary.text(forFileAt: file.path) == "Read & Write")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        #expect(AccessSummary.text(forFileAt: file.path) == "Read Only")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(AccessSummary.text(forFileAt: s.url.appendingPathComponent("missing").path) == "No Access")
    }
}
