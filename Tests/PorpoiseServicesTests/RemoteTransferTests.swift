import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// Jobs with a non-file URL go the remote way. Without connecting anywhere, these check what it refuses.
@MainActor @Suite(.isolatedSettings) struct RemoteTransferTests {
    @Test func linksCannotBeMadeToRemoteItems() async throws {
        let s = try Scratch()
        let ui = ScriptedUI()
        let results = await makeController(ui).perform(.link, [URL(string: "unknown://host/file.txt")!], to: s.url)
        #expect(results.isEmpty && s.listing().isEmpty)
        #expect(ui.errors == ["file.txt: Links can't be created across remote locations."])
    }

    @Test func anExistingNameIsReportedNeverOverwritten() async throws {
        let s = try Scratch()
        try s.file("file.txt", "local")
        let ui = ScriptedUI()
        let results = await makeController(ui).perform(.copy, [URL(string: "unknown://host/file.txt")!], to: s.url)
        #expect(results.isEmpty && s.read("file.txt") == "local")
        #expect(ui.errors.count == 1 && ui.conflicts.isEmpty)
    }

    @Test func aLocalItemInAMixedSelectionIsStillCopied() async throws {
        let s = try Scratch()
        let f = try s.file("src/local.txt", "local")
        let ui = ScriptedUI()
        let results = await makeController(ui).perform(.copy, [URL(string: "unknown://host/remote.txt")!, f], to: try s.folder("dst"))
        #expect(results.map(\.lastPathComponent) == ["local.txt"])
        #expect(s.read("dst/local.txt") == "local" && s.read("src/local.txt") == "local")
        #expect(ui.errors.count == 1)
    }

    @Test func itemsCannotBePutIntoAnUnknownKindOfLocation() async throws {
        let s = try Scratch()
        let f = try s.file("file.txt", "local")
        let ui = ScriptedUI()
        let results = await makeController(ui).perform(.move, [f], to: URL(string: "unknown://host/folder/")!)
        #expect(results.isEmpty && s.read("file.txt") == "local")
        #expect(ui.errors.count == 1)
    }
}
