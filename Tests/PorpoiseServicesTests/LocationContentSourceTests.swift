import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Each kind of location lists through its own source; the model only applies what a source delivers.
@MainActor @Suite(.isolatedSettings) struct LocationContentSourceTests {
    /// Lists `folder` through `source` and waits for the last page.
    func listing(_ source: LocationContentSource, _ folder: URL, expanded: Set<URL> = []) async throws -> LocationListing {
        var answer: LocationListing?
        _ = source.load(folder, expanded: expanded) { if $0.complete { answer = $0 } }
        try #require(await eventually { answer != nil })
        return try #require(answer)
    }

    @Test func failuresKeepTheirWords() {
        #expect(LocationLoadError.permission.message == "You don't have permission to view this folder.")
        #expect(LocationLoadError.privacy.message.hasPrefix("macOS protects this folder. Give Porpoise Full Disk Access"))
        #expect(LocationLoadError.unreadable("gone").message == "Could not open “gone”.")
        #expect(LocationLoadError.provider("Server said no").message == "Server said no")
        #expect(LocationLoadError.smartFolder.message == "This Smart Folder's search could not be read.")
    }

    @Test func aLocalFolderListsWithItsExpandedFolders() async throws {
        let s = try Scratch()
        try s.file("a.txt"); try s.file("sub/b.txt")
        let source = LocationContentSources.source(for: s.url)
        #expect(source is LocalSource && source.traits.watch == .fileSystem && source.traits.dynamicView && source.traits.folderCounts)
        let found = try await listing(source, s.url, expanded: [s.path("sub")])
        #expect(Set(found.items.map(\.name)) == ["a.txt", "sub"] && found.error == nil && found.vanished == false)
        #expect(found.children?[s.path("sub")]?.map(\.name) == ["b.txt"])
        let gone = try await listing(source, s.path("gone"))
        #expect(gone.error == .unreadable("gone") && gone.vanished == true && gone.items.isEmpty)
    }

    @Test func aFolderThatIsntAFileIsNeitherWatchedNorCounted() {
        let traits = LocalSource(location: URL(string: "smb://server/share")!).traits
        #expect(traits.watch == .none && !traits.dynamicView && !traits.folderCounts && traits.prunesSelection)
    }
}
