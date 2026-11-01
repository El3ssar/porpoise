import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices
import PorpoiseTestSupport
import Testing

@testable import Porpoise

struct NewItemCreationTests {
    @Test func generatedArtifactsHaveTheirAdvertisedContents() throws {
        let scratch = try Scratch("new-item-artifacts")
        let html = NewItemCreation(kind: .htmlFile, folder: scratch.url, name: "page.html", target: "")
        #expect(try Data(contentsOf: html.create()) == NewItemKind.htmlTemplate)
        let location = NewItemCreation(kind: .urlLink, folder: scratch.url, name: "site.webloc", target: "https://example.test/path")
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: location.create()), format: nil) as? [String: String]
        #expect(value?["URL"] == "https://example.test/path")
    }

    @Test func creationRefusesAnExistingFolderAndFileWithoutModifyingThem() throws {
        let scratch = try Scratch("new-item-exclusive")
        try scratch.file("folder/other.txt", "keep")
        try scratch.file("file.txt", "keep file")
        #expect(throws: (any Error).self) {
            try NewItemCreation(kind: .folder, folder: scratch.url, name: "folder", target: "").create()
        }
        #expect(throws: (any Error).self) {
            try NewItemCreation(kind: .emptyFile, folder: scratch.url, name: "file.txt", target: "").create()
        }
        #expect(scratch.read("folder/other.txt") == "keep" && scratch.read("file.txt") == "keep file")
        #expect(throws: (any Error).self) {
            try NewItemCreation(kind: .link, folder: scratch.url, name: "../escape", target: "something").create()
        }
    }

    @Test(arguments: [false, true])
    func authorizedFileMustConsumeItsPublicationStageBeforeReceivingUndo(_ occupied: Bool) throws {
        let scratch = try Scratch("new-item-publication-proof")
        let request = NewItemCreation(kind: .htmlFile, folder: scratch.url, name: "page.html", target: "")
        let authorization = try request.prepareAuthorization()
        defer { if let temporary = authorization.contentsFile { try? FileManager.default.removeItem(at: temporary) } }
        if occupied { try NewItemKind.htmlTemplate.write(to: request.url) }
        let prior = JobJournal.Fingerprint(request.url)
        for command in authorization.commands {
            let result = try Shell.run(command[0], Array(command.dropFirst()))
            try #require(result.status == 0)
        }
        var undo: UndoRecord?
        do {
            try authorization.verifyPublication(at: request.url)
            undo = .created([request.url])
        } catch {
            #expect(occupied)
        }
        if occupied {
            #expect(undo == nil)
            #expect(JobJournal.Fingerprint(request.url) == prior)
            #expect(try Data(contentsOf: request.url) == NewItemKind.htmlTemplate)
            #expect(FileJob.itemExists(at: try #require(authorization.publicationStage)))
        } else {
            #expect(undo != nil)
            #expect(!FileJob.itemExists(at: try #require(authorization.publicationStage)))
        }
    }

    @Test func administratorFolderStillRequestsExclusiveLeafWhenItAppeared() throws {
        let scratch = try Scratch("new-item-authorized-leaf")
        let leaf = try scratch.folder("appeared")
        let commands = NewItemCreation.administratorCommands(.folder, at: leaf, in: scratch.url, linkTarget: "", contents: nil)
        #expect(commands == [["/bin/mkdir", "--", leaf.path]])
        let result = try Shell.run(commands[0][0], Array(commands[0].dropFirst()))
        #expect(result.status != 0)
    }
}
