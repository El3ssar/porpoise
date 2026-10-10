import Foundation
import Testing
@testable import PorpoiseServices
import PorpoiseTestSupport

/// Places kept in a places.json inside a throwaway folder. On the main actor, as in the app: PlacesModel and IconTheme
/// (its lookup cache) are main-thread only.
@MainActor @Suite struct PlacesModelTests {
    let home = FileManager.default.homeDirectoryForCurrentUser

    private func titles(_ m: PlacesModel, _ section: PlaceSection) -> [String] {
        m.sections().first { $0.0 == section }?.1.map(\.title) ?? []
    }

    private func entry(_ m: PlacesModel, _ title: String) throws -> PlaceEntry {
        try #require(m.userEntries.first { $0.title == title })
    }

    @Test func startsWithTheDefaultPlaces() throws {
        let s = try Scratch()
        let m = PlacesModel(storeURL: s.path("places.json"))
        #expect(titles(m, .places) == ["Home", "Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos",
                                      "Applications", "Trash"])
        #expect(titles(m, .remote).contains("Network"))
        #expect(titles(m, .recent) == ["Recent Files", "Recent Locations"])
        #expect(titles(m, .tags) == ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        #expect(m.title(for: home) == "Home")
        #expect(m.contains(URL(fileURLWithPath: "/Applications")))
        #expect(m.title(for: URL(string: "smart:/x/Big%20Files.savedSearch")!) == "Big Files")
        #expect(s.listing().isEmpty)   // nothing written until something changes
    }

    @Test func addedPlacesGoBeforeTheTrashAndPersist() throws {
        let s = try Scratch()
        let store = s.path("places.json")
        let m = PlacesModel(storeURL: store)
        let work = try s.folder("Work")
        m.add(work)
        m.add(work)   // once only
        m.add(URL(string: "sftp://server.local/srv")!)
        #expect(titles(m, .places).suffix(3) == ["Applications", "Work", "Trash"])
        #expect(titles(m, .remote).last == "server.local")
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
        #expect(m.title(for: s.url) == "Songs" && !titles(m, .places).contains("Music"))

        m.setHidden(try entry(m, "Pictures"), true)
        #expect(!titles(m, .places).contains("Pictures"))
        m.showHidden = true
        #expect(titles(m, .places).contains("Pictures"))
        m.showHidden = false

        let videos = try entry(m, "Videos")
        #expect(m.isUserEntry(videos))
        m.remove(videos)
        #expect(!m.isUserEntry(videos) && !titles(m, .places).contains("Videos"))
        m.remove(videos)   // already gone: nothing happens

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
        #expect(titles(m, .places).prefix(2) == ["Trash", "Home"])
        m.move(trash, before: nil, endOf: .places)
        #expect(titles(m, .places).last == "Trash")

        #expect(!m.canMove(docs, before: recent, endOf: .recent))   // another section
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
        #expect(!m.canMoveSection(.places, before: .remote))   // already there
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
        let store = try s.file("places.json", """
        {"hiddenSections":["Tags"],"entries":[
          {"title":"Home","url":"\(home.absoluteString)","icon":"user-home","section":"Places","hidden":false,"isVolume":false,"isEjectable":false},
          {"title":"Apps","url":"file:///Applications/","icon":"folder-appimage","section":"Places","hidden":false,"isVolume":false,"isEjectable":false},
          {"title":"Stuff","url":"file:///tmp/stuff/","icon":"no-such-icon","section":"Places","hidden":false,"isVolume":false,"isEjectable":false},
          {"title":"Server","url":"sftp://server/","icon":"gone-too","section":"Remote","hidden":false,"isVolume":false,"isEjectable":false}
        ]}
        """)
        let m = PlacesModel(storeURL: store)
        #expect(m.userEntries.map(\.title) == ["Home", "Apps", "Stuff", "Network", "Server"])
        #expect(m.userEntries.map(\.icon) == ["user-home", "view-list-icons", "folder", "network-workgroup", "folder-remote"])
        #expect(m.hiddenSections == [.tags])
        #expect(m.sections().map(\.0).first == .places)

        // Removed afterwards: it stays removed.
        m.remove(try entry(m, "Network"))
        let again = PlacesModel(storeURL: store)
        #expect(again.userEntries.map(\.title) == ["Home", "Apps", "Stuff", "Server"])
        #expect(try String(contentsOf: store, encoding: .utf8).contains("\"version\":1"))
    }

    @Test func aDamagedFileIsKeptAside() throws {
        let s = try Scratch()
        let store = try s.file("places.json", "{ not json")
        let m = PlacesModel(storeURL: store)
        #expect(m.userEntries == PlacesModel.defaultEntries())
        #expect(s.read("places.unreadable.json") == "{ not json")
        #expect(s.read("places.json") == "{ not json")   // untouched until the user changes something
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
        #expect(found.map(\.title) == ["Box (Work)", "Dropbox", "Google Drive (me@example.com)", "Nextcloud (a-b)",
                                       "OneDrive (Personal)", "pCloud"])
        #expect(found.map(\.icon) == ["folder-cloud", "folder-dropbox", "folder-gdrive", "folder-cloud", "folder-onedrive",
                                      "folder-pcloud"])
        #expect(CloudStorage.locations(in: s.path("missing")).isEmpty)
    }
}
