import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Each kind of location lists through its own source; the model only applies what a source delivers.
@MainActor @Suite(.isolatedSettings) struct LocationContentSourceTests {
    /// Lists `folder` through `source` and waits for the last page.
    func listing(_ source: LocationContentSource, _ folder: URL, expanded: Set<URL> = []) async throws -> LocationListing {
        var answer: LocationListing?
        let load = source.load(folder, expanded: expanded) { if $0.complete { answer = $0 } }
        defer { load.cancel() }
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

    @Test func aServerFolderListsThroughItsProviderInItsWords() async throws {
        let root = URL(string: "sftp://source-test.invalid/")!
        let provider = ListingProvider()
        RemoteFS.use(provider, for: root)
        defer { RemoteFS.use(nil, for: root) }
        let source = LocationContentSources.source(for: root)
        #expect(source is ProviderSource && source.traits.watch == .none && source.traits.optimisticEdits && !source.traits.clearsCurrentItem)
        let sub = root.appendingPathComponent("sub")
        let found = try await listing(source, root, expanded: [sub, root.appendingPathComponent("locked")])
        #expect(found.items.map(\.name) == ["sub"] && found.error == nil && found.vanished == nil)
        #expect(found.children?[sub]?.map(\.name) == ["inner"] && found.children?[root.appendingPathComponent("locked")] == [])
        let refused = try await listing(source, root.appendingPathComponent("locked"))
        #expect(refused.error == .provider("Server said no") && refused.items.isEmpty)
    }

    @Test func anUnreadableSmartFolderSaysSo() async throws {
        let smart = URL(string: "smart:/nonexistent-\(UUID().uuidString).savedSearch")!
        #expect(LocationContentSources.source(for: smart) is SpotlightListSource)
        #expect(LocationContentSources.source(for: URL(string: "tags:/fixture")!) is SpotlightListSource)
        let model = DirectoryModel(location: smart, prefetchFolders: false)
        var loaded = 0
        model.onLoaded = { loaded += 1 }
        model.reload()
        #expect(model.loadError == "This Smart Folder's search could not be read.")
        #expect(!model.isLoading && model.items.isEmpty && loaded == 1)
    }

    @Test func recentLocationsListTheFoldersVisited() async throws {
        let recent = URL(string: "recent:/locations")!
        let source = LocationContentSources.source(for: recent)
        #expect(source is RecentSource && LocationContentSources.source(for: URL(string: "recent:/files")!) is RecentSource)
        let expected = RecentLocations.shared.urls.compactMap { FileItem.load($0)?.url }
        let listed = try await listing(source, recent)
        #expect(listed.items.map(\.url) == expected)
        #expect(!source.traits.prunesSelection && !source.traits.optimisticEdits && source.traits.watch == .none)
    }

    @Test func everyKindHasItsSource() {
        #expect(LocationContentSources.source(for: URL(string: "network:/")!) is NetworkSource)
        Settings.shared.appLibraryView = true
        let apps = LocationContentSources.source(for: AppLibrary.location)
        #expect(apps is AppLibrarySource && apps.traits.watch == .appLibrary && apps.traits.prunesSelection)
        Settings.shared.appLibraryView = false
        #expect(LocationContentSources.source(for: AppLibrary.location) is LocalSource)
        // Dropbox without a connected account has no provider: it lists as a folder that can't be opened, as before.
        #expect(LocationContentSources.source(for: URL(string: "dropbox://\(UUID().uuidString)/")!) is LocalSource)
    }
}

/// A server whose root holds "sub" (holding "inner") and whose "locked" folder refuses to be listed.
private final class ListingProvider: RemoteProvider {
    struct Refusal: LocalizedError { var errorDescription: String? { "Server said no" } }
    func list(_ folder: URL) throws -> [FileItem] {
        switch folder.lastPathComponent {
        case "locked": throw Refusal()
        case "sub": return [FileItem(url: folder.appendingPathComponent("inner"), name: "inner", isDirectory: false)]
        default: return [FileItem(url: folder.appendingPathComponent("sub"), name: "sub", isDirectory: true)]
        }
    }
    func download(_ remote: URL, into localFolder: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
    func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
    func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
    func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
    func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
    func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func rootTitle(_ url: URL) -> String { "Test server" }
}
