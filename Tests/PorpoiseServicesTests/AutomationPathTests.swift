import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct AutomationPathTests {
    @Test func symlinkThenParentMovesTheItemTheCallerNamed() throws {
        let scratch = try Scratch()
        try scratch.folder("elsewhere/child")
        try scratch.folder("elsewhere/output")
        try scratch.folder("output")
        try scratch.symlink("link", to: "elsewhere/child")
        let intended = try scratch.file("elsewhere/item", "intended")
        let other = try scratch.file("item", "leave alone")
        let request = try AutomationCLI.parse(["move", "link/../item", "--to", "link/../output"], directory: scratch.url.path).request
        let sources = try AutomationLocations.localURLs(request.paths, folders: false)
        let destination = try #require(AutomationLocations.localURLs([try #require(request.destination)], folders: true).first)
        #expect(sources == [intended])
        #expect(destination.path == scratch.path("elsewhere/output").path)
        let job = FileJob(kind: .move, sources: sources, destinationFolder: destination)
        _ = try job.run()
        #expect(job.errors.isEmpty && scratch.read("elsewhere/output/item") == "intended")
        #expect(!FileManager.default.fileExists(atPath: intended.path))
        #expect(try String(contentsOf: other, encoding: .utf8) == "leave alone")
        #expect(scratch.listing("output").isEmpty)
    }

    @Test func resolvingParentsKeepsTheSelectedLeafSymlink() throws {
        let scratch = try Scratch()
        let original = try scratch.file("original", "target")
        let link = try scratch.symlink("leaf", to: original.path)
        let selected = try #require(AutomationLocations.localURLs([link.path], folders: false).first)
        #expect(selected == link)
        let job = FileJob(kind: .move, sources: [selected], destinationFolder: try scratch.folder("out"))
        _ = try job.run()
        #expect(job.errors.isEmpty && scratch.read("original") == "target")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scratch.path("out/leaf").path) == original.path)
    }
}
