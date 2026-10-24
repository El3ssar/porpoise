import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Places kept in a places.json inside a throwaway folder. On the main actor, as in the app: PlacesModel and IconTheme
/// (its lookup cache) are main-thread only.
@MainActor @Suite struct PlacesModelTests {
    let home = FileManager.default.homeDirectoryForCurrentUser

    private func entry(_ m: PlacesModel, _ title: String) throws -> PlaceEntry {
        try #require(m.userEntries.first { $0.title == title })
    }

    @Test func retiredSectionsPreserveBookmarksAndOrdering() throws {
        let scratch = try Scratch(), file = scratch.path("places.json")
        let model = PlacesModel(storeURL: file)
        model.add(URL(fileURLWithPath: "/my-folder"), title: "My folder")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["hiddenSections"] = ["Sync", "Tags"]
        object["collapsedSections"] = ["Sync", "Remote"]
        object["sectionOrder"] = ["Remote", "Sync", "Places"]
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries.append(["id": UUID().uuidString, "title": "Retired pair", "url": "porpoise-sync://retired", "icon": "folder", "section": "Sync"])
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let restored = PlacesModel(storeURL: file)
        #expect(restored.userEntries.contains { $0.title == "My folder" })
        #expect(!restored.userEntries.contains { $0.title == "Retired pair" })
        #expect(restored.hiddenSections == [.tags])
        #expect(restored.collapsedSections == [.remote])
        #expect(restored.sectionOrder.prefix(2) == [.remote, .places])
        #expect(!FileManager.default.fileExists(atPath: scratch.path("places.unreadable.json").path))
    }

    @Test func startsWithTheDefaultPlaces() throws {
        let s = try Scratch()
        let m = PlacesModel(storeURL: s.path("places.json"))
        #expect(
            m.titles(in: .places) == [
                "AirDrop", "Home", "Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies",
                "Applications", "Trash",
            ])
        #expect(m.titles(in: .remote).contains("Network"))
        #expect(m.titles(in: .recent) == ["Recent Files", "Recent Locations"])
        #expect(m.titles(in: .tags) == ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        #expect(m.title(for: home) == "Home")
        #expect(m.contains(URL(fileURLWithPath: "/Applications")))
        #expect(m.title(for: URL(string: "smart:/x/Big%20Files.savedSearch")!) == "Big Files")
        #expect(s.listing().isEmpty)  // nothing written until something changes
    }

    @Test func addedPlacesGoBeforeTheTrashAndPersist() throws {
        let s = try Scratch()
        let store = s.path("places.json")
        let m = PlacesModel(storeURL: store)
        let work = try s.folder("Work")
        m.add(work)
        m.add(work)  // once only
        m.add(URL(string: "sftp://server.local/srv")!)
        #expect(m.titles(in: .places).suffix(3) == ["Applications", "Work", "Trash"])
        #expect(m.titles(in: .remote).last == "server.local")
        #expect(try entry(m, "Work").icon == "folder")
        #expect(try entry(m, "server.local").icon == "folder-remote")

        let reloaded = PlacesModel(storeURL: store)
        #expect(reloaded.userEntries == m.userEntries)
    }

    @Test func editingEntries() throws {
        let s = try Scratch()
        let store = s.path("places.json")
        let m = PlacesModel(storeURL: store)
        m.update(try entry(m, "Music"), title: "Songs", url: s.url)
        #expect(m.title(for: s.url) == "Songs" && !m.titles(in: .places).contains("Music"))

        m.setHidden(try entry(m, "Pictures"), true)
        #expect(!m.titles(in: .places).contains("Pictures"))
        m.showHidden = true
        #expect(m.titles(in: .places).contains("Pictures"))
        m.showHidden = false

        let videos = try entry(m, "Movies")
        #expect(m.isUserEntry(videos))
        let order = m.userEntries
        let at = try #require(m.removeForUndo(videos))
        #expect(!m.isUserEntry(videos) && !m.titles(in: .places).contains("Movies"))
        #expect(m.removeForUndo(videos) == nil)  // already gone: nothing happens
        // Undo puts it back where it was, once.
        m.restore(videos, at: at)
        m.restore(videos, at: at)
        #expect(m.userEntries == order)
        m.remove(videos)

        let reloaded = PlacesModel(storeURL: store)
        #expect(reloaded.userEntries == m.userEntries)
        #expect(try entry(reloaded, "Pictures").hidden)
    }

    @Test func entriesMoveOnlyWithinTheirSection() throws {
        let s = try Scratch()
        let m = PlacesModel(storeURL: s.path("places.json"))
        let home = try entry(m, "Home"), trash = try entry(m, "Trash"), docs = try entry(m, "Documents")
        let recent = try entry(m, "Recent Files")

        m.move(trash, before: home, endOf: .places)
        #expect(m.titles(in: .places).prefix(3) == ["AirDrop", "Trash", "Home"])
        m.move(trash, before: nil, endOf: .places)
        #expect(m.titles(in: .places).last == "Trash")

        #expect(!m.canMove(docs, before: recent, endOf: .recent))  // another section
        #expect(!m.canMove(docs, before: nil, endOf: .recent))
        #expect(!m.canMove(docs, before: docs, endOf: .places))
        #expect(m.canMove(docs, before: home, endOf: .places))
        let before = m.userEntries
        m.move(docs, before: recent, endOf: .recent)
        #expect(m.userEntries == before)
    }

    @Test func sectionsFoldHideLockAndReorder() throws {
        let s = try Scratch()
        let store = s.path("places.json")
        let m = PlacesModel(storeURL: store)

        #expect(!m.canMoveSection(.tags, before: .tags))
        #expect(!m.canMoveSection(.places, before: .remote))  // already there
        m.moveSection(.tags, before: .places)
        #expect(m.sections().map(\.0).prefix(2) == [.tags, .places])
        m.moveSection(.tags, before: nil)
        #expect(m.sectionOrder.last == .tags)

        m.hiddenSections = [.recent]
        #expect(!m.sections().map(\.0).contains(.recent))
        m.toggleCollapsed(.remote)
        m.isLocked = true

        let reloaded = PlacesModel(storeURL: store)
        #expect(reloaded.hiddenSections == [.recent])
        #expect(reloaded.collapsedSections == [.remote])
        #expect(reloaded.isLocked)
        #expect(reloaded.sections().map(\.0) == m.sections().map(\.0))
        reloaded.toggleCollapsed(.remote)
        #expect(reloaded.collapsedSections.isEmpty)

        reloaded.resetDefaults()
        #expect(reloaded.hiddenSections.isEmpty && reloaded.collapsedSections.isEmpty)
        #expect(reloaded.sections().first?.0 == .places)
        #expect(reloaded.userEntries == PlacesModel.defaultEntries())
    }

    /// A places.json from before the format version: old icons are replaced, the Network place is offered once, and
    /// the file is rewritten so that happens only once.
    @Test func migratesAnOldPlacesFile() throws {
        let s = try Scratch()
        let store = try s.file(
            "places.json",
            """
            {"hiddenSections":["Tags"],"entries":[
              {"title":"Home","url":"\(home.absoluteString)","icon":"user-home","section":"Places","hidden":false,"isVolume":false,"isEjectable":false},
              {"title":"Apps","url":"file:///Applications/","icon":"folder-appimage","section":"Places","hidden":false,"isVolume":false,"isEjectable":false},
              {"title":"Stuff","url":"file:///tmp/stuff/","icon":"no-such-icon","section":"Places","hidden":false,"isVolume":false,"isEjectable":false},
              {"title":"Server","url":"sftp://server/","icon":"gone-too","section":"Remote","hidden":false,"isVolume":false,"isEjectable":false}
            ]}
            """)
        let m = PlacesModel(storeURL: store)
        #expect(m.userEntries.map(\.title) == ["AirDrop", "Home", "Apps", "Stuff", "Network", "Server"])
        #expect(m.userEntries.map(\.icon) == ["airdrop", "user-home", "view-list-icons", "folder", "network-workgroup", "folder-remote"])
        #expect(m.hiddenSections == [.tags])
        #expect(m.sections().map(\.0).first == .places)

        // Removed afterwards: it stays removed.
        m.remove(try entry(m, "Network"))
        let again = PlacesModel(storeURL: store)
        #expect(again.userEntries.map(\.title) == ["AirDrop", "Home", "Apps", "Stuff", "Server"])
        #expect(try String(contentsOf: store, encoding: .utf8).contains("\"version\":3"))
    }

    @Test func aDamagedFileIsKeptAside() throws {
        let s = try Scratch()
        let store = try s.file("places.json", "{ not json")
        let m = PlacesModel(storeURL: store)
        #expect(m.userEntries == PlacesModel.defaultEntries())
        #expect(s.read("places.unreadable.json") == "{ not json")
        #expect(s.read("places.json") == "{ not json")  // untouched until the user changes something
    }

    @Test func withoutAFileNothingIsWritten() throws {
        let m = PlacesModel(storeURL: nil)
        m.add(URL(fileURLWithPath: "/tmp"))
        #expect(m.contains(URL(fileURLWithPath: "/tmp")))
    }

    @Test func cloudStorageFolders() throws {
        let s = try Scratch()
        for n in ["GoogleDrive-me@example.com", "OneDrive-Personal", "Dropbox", "Box-Work", "pCloud Drive", "Nextcloud-a-b", ".hidden"] {
            try s.folder(n)
        }
        let found = CloudStorage.locations(in: s.url)
        #expect(
            found.map(\.title) == [
                "Box (Work)", "Dropbox", "Google Drive (me@example.com)", "Nextcloud (a-b)",
                "OneDrive (Personal)", "pCloud",
            ])
        #expect(
            found.map(\.icon) == [
                "folder-cloud", "folder-dropbox", "folder-gdrive", "folder-cloud", "folder-onedrive",
                "folder-pcloud",
            ])
        #expect(CloudStorage.locations(in: s.path("missing")).isEmpty)
    }

    @Test func tagsListOnlyTagsInUse() throws {
        let s = try Scratch()
        let m = PlacesModel(storeURL: s.path("places.json"))
        func tags() -> [String] { m.sections().first { $0.0 == .tags }?.1.map(\.title) ?? [] }
        // Until Spotlight answers (or when it can't), every standard tag.
        #expect(tags() == FinderTags.standard.map(\.name))
        m.usedTags = ["Blue", "Red"]
        #expect(tags() == ["Red", "Blue"])  // in Finder's order
        // No tag in use: no Tags section at all.
        m.usedTags = []
        #expect(m.sections().allSatisfy { $0.0 != .tags })
        m.usedTags = nil
        #expect(tags().count == FinderTags.standard.count)
    }

    @Test func airDropPlaceIsMigratedOnlyOnceAndCanBeHiddenOrRemoved() throws {
        let scratch = try Scratch(), file = scratch.path("places.json")
        let model = PlacesModel(storeURL: file)
        let airDrop = try #require(model.userEntries.first { $0.url == PlacesModel.airDropURL })
        model.setHidden(airDrop, true)
        #expect(!PlacesModel(storeURL: file).sections().flatMap(\.1).contains { $0.url == PlacesModel.airDropURL })
        model.remove(airDrop)
        #expect(!PlacesModel(storeURL: file).userEntries.contains { $0.url == PlacesModel.airDropURL })
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        document["version"] = 1
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let migrated = PlacesModel(storeURL: file)
        #expect(migrated.userEntries.filter { $0.url == PlacesModel.airDropURL }.count == 1)
        let again = PlacesModel(storeURL: file)
        #expect(again.userEntries == migrated.userEntries)
    }

    /// Version 3 renames the untouched "Videos" place (~/Movies) to "Movies"; a name the user chose stays.
    @Test func videosBecomesMovies() throws {
        let scratch = try Scratch(), file = scratch.path("places.json")
        let model = PlacesModel(storeURL: file)
        let movies = try entry(model, "Movies")
        model.add(scratch.url)
        let added = try #require(model.userEntries.first { $0.url.standardizedFileURL == scratch.url.standardizedFileURL })
        model.update(added, title: "Videos", url: scratch.url)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var entries = try #require(document["entries"] as? [[String: Any]])
        for i in entries.indices where (entries[i]["title"] as? String) == "Movies" { entries[i]["title"] = "Videos" }
        document["entries"] = entries
        document["version"] = 2
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let migrated = PlacesModel(storeURL: file)
        #expect(migrated.title(for: movies.url) == "Movies")
        // Another folder the user named "Videos" keeps its name.
        #expect(migrated.userEntries.contains { $0.url == added.url && $0.title == "Videos" })
        #expect(migrated.userEntries.filter { $0.title == "Videos" }.count == 1)
    }
}
