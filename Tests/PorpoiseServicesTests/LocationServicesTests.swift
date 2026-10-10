import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseServices

// MARK: Tags and comments (extended attributes on real files)

@Suite struct FinderTagsTests {
    private let tagsAttr = "com.apple.metadata:_kMDItemUserTags"

    private func setTagsAttribute(_ entries: [String], on url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let r = data.withUnsafeBytes { setxattr(url.path, tagsAttr, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        try #require(r == 0)
    }

    @Test func tagsWrittenAreReadBack() throws {
        let s = try Scratch()
        let f = try s.file("doc.txt")
        #expect(FinderTags.read(f).isEmpty)
        FinderTags.set(["Red", "Project"], on: f)
        #expect(FinderTags.read(f).map(\.name) == ["Red", "Project"])
        #expect(FinderTags.read(f).first?.color == 6)
        FinderTags.set([], on: f)
        #expect(FinderTags.read(f).isEmpty)
    }

    @Test func colorsComeFromTheAttribute() throws {
        let s = try Scratch()
        let f = try s.file("doc.txt")
        try setTagsAttribute(["Work\n4", "Green", "Odd\nx", ""], on: f)
        #expect(
            FinderTags.read(f) == [
                FinderTags.Tag(name: "Work", color: 4), FinderTags.Tag(name: "Green", color: 2),
                FinderTags.Tag(name: "Odd", color: 0), FinderTags.Tag(name: "", color: 0),
            ])
    }

    @Test func damagedAttributeAndLinks() throws {
        let s = try Scratch()
        let f = try s.file("doc.txt")
        let junk = Data("not a plist".utf8)
        _ = junk.withUnsafeBytes { setxattr(f.path, tagsAttr, $0.baseAddress, junk.count, 0, 0) }
        #expect(FinderTags.read(f).isEmpty)
        // A symlink's own tags, not its target's.
        let target = try s.file("target")
        try setTagsAttribute(["Red\n6"], on: target)
        let link = try s.symlink("link", to: "target")
        #expect(FinderTags.read(link).isEmpty)
        #expect(FinderTags.read(URL(string: "sftp://host/file")!).isEmpty)
    }

    @Test func tagLocations() {
        #expect(FinderTags.url(for: "Red").absoluteString == "tags:/Red")
        #expect(FinderTags.url(for: "My Work").absoluteString == "tags:/My%20Work")
        #expect(FinderTags.standard.map(\.color) == [6, 7, 5, 2, 4, 3, 1])
    }

    @Test func comments() throws {
        let s = try Scratch()
        let f = try s.file("doc.txt")
        #expect(FinderComment.read(f) == "")
        FinderComment.write("Signed copy — keep", to: f)
        #expect(FinderComment.read(f) == "Signed copy — keep")
        FinderComment.write("", to: f)
        #expect(FinderComment.read(f) == "")
        #expect(getxattr(f.path, "com.apple.metadata:kMDItemFinderComment", nil, 0, 0, 0) == -1)  // removed, not left empty
    }
}

/// Sorting and grouping by tags in a real folder.
@MainActor @Suite(.isolatedSettings) struct TaggedFolderTests {
    @Test func sortAndGroupByTags() async throws {
        let s = try Scratch()
        FinderTags.set(["Red"], on: try s.file("b"))
        FinderTags.set(["Blue"], on: try s.file("c"))
        try s.file("a")
        let m = DirectoryModel(location: s.url)
        m.reload()
        #expect(await eventually { !m.isLoading })
        m.props.sortRole = .tags
        #expect(m.rows.map(\.item.name) == ["c", "b", "a"])
        m.props.groupSameAsSort = true
        #expect(m.groups.map(\.title) == ["Blue", "Red", "No Tags"])
        #expect(m.text(for: .tags, of: m.rows[1].item) == "Red")
        // Tagging is seen after a refresh.
        FinderTags.set(["Green"], on: s.path("a"))
        m.refreshTags()
        m.rebuild()
        #expect(m.groups.map(\.title) == ["Blue", "Green", "Red"])
    }
}

// MARK: Archives

@MainActor @Suite struct ArchiveBrowserTests {
    private func extract(_ archive: URL, cache: URL) async throws -> Result<URL, Error> {
        let item = try #require(FileItem.load(archive))
        var result: Result<URL, Error>?
        ArchiveBrowser.extractedFolder(for: item, in: cache) { result = $0 }
        try #require(await eventually(30) { result != nil })  // a regression fails here instead of hanging
        return try #require(result)
    }

    @Test func recognizesArchives() throws {
        func item(_ name: String, dir: Bool = false) -> FileItem { FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: dir) }
        for n in ["a.zip", "a.ZIP", "a.tar", "a.tar.gz", "a.tgz", "a.tar.xz", "a.7z", "a.rar", "a.iso", "a.jar"] {
            #expect(ArchiveBrowser.isArchive(item(n)), "\(n)")
        }
        #expect(!ArchiveBrowser.isArchive(item("a.txt")))
        #expect(!ArchiveBrowser.isArchive(item("folder.zip", dir: true)))
    }

    @Test func zipAndTarOpenAsFolders() async throws {
        let s = try Scratch()
        try s.file("src/readme.txt", "hello")
        try s.file("src/sub/inner.txt", "inner")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", s.path("src").path, s.path("ditto.zip").path])
        try run("/usr/bin/zip", ["-qr", s.path("plain.zip").path, "src"], in: s.url)
        try run("/usr/bin/tar", ["-czf", s.path("files.tar.gz").path, "-C", s.url.path, "src"])
        let cache = s.path("cache")
        for name in ["ditto.zip", "plain.zip", "files.tar.gz"] {
            let dir = try await extract(s.path(name), cache: cache).get()
            #expect(dir.lastPathComponent == name)
            let readme = dir.appendingPathComponent("src/readme.txt")
            #expect(try String(contentsOf: readme, encoding: .utf8) == "hello", "\(name)")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("src/sub/inner.txt").path))
        }
        // No unfinished extractions left behind.
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: cache.path).filter { $0.contains(".partial-") }
        #expect(leftovers.isEmpty)
    }

    @Test func extractsOncePerVersion() async throws {
        let s = try Scratch()
        try s.file("src/a.txt", "one")
        let archive = s.path("a.tar")
        try run("/usr/bin/tar", ["-cf", archive.path, "-C", s.path("src").path, "a.txt"])
        let cache = s.path("cache")
        let first = try await extract(archive, cache: cache).get()
        try "marker".write(to: first.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        let again = try await extract(archive, cache: cache).get()
        #expect(again.path == first.path)
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("marker").path))

        // A changed archive is extracted again, and the copy of the old one goes.
        try "two".write(to: s.path("src/a.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/tar", ["-cf", archive.path, "-C", s.path("src").path, "a.txt"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: archive.path)
        let second = try await extract(archive, cache: cache).get()
        #expect(second.path != first.path)
        #expect(try String(contentsOf: second.appendingPathComponent("a.txt"), encoding: .utf8) == "two")
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
    }

    /// Two requests for the same archive at once (two views opening it): both get the one finished copy.
    @Test func concurrentRequestsShareOneCopy() async throws {
        let s = try Scratch()
        for i in 0..<200 { try s.file("src/f\(i).txt", "\(i)") }
        let archive = s.path("many.tar")
        try run("/usr/bin/tar", ["-cf", archive.path, "-C", s.url.path, "src"])
        let item = try #require(FileItem.load(archive))
        let cache = s.path("cache")
        var results: [Result<URL, Error>] = []
        for _ in 0..<3 { ArchiveBrowser.extractedFolder(for: item, in: cache) { results.append($0) } }
        #expect(await eventually { results.count == 3 })
        let dirs = try results.map { try $0.get().path }
        #expect(Set(dirs).count == 1)
        #expect(s.listing("cache").count == 1)
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: cache.path).filter { $0.contains(".partial-") }
        #expect(leftovers.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dirs[0] + "/src").count == 200)
    }

    @Test func notAnArchive() async throws {
        let s = try Scratch()
        let fake = try s.file("fake.zip", "just text")
        let cache = s.path("cache")
        let result = try await extract(fake, cache: cache)
        #expect(throws: (any Error).self) { try result.get() }
        // Neither a half-extracted copy nor one that looks finished.
        let left = try FileManager.default.subpathsOfDirectory(atPath: cache.path)
        #expect(!left.contains { $0.contains(".partial-") || $0.hasSuffix("fake.zip") })
    }

    /// Entries that point outside the extraction folder never write there.
    @Test func hostileEntriesStayInside() async throws {
        let s = try Scratch()
        // "../escaped.txt": made from a folder one level down, keeping the "..".
        try s.file("work/escaped.txt", "evil")
        try s.folder("work/down")
        try run("/usr/bin/tar", ["-cPf", s.path("dotdot.tar").path, "../escaped.txt"], in: s.path("work/down"))
        // An absolute path to a file that exists.
        let victim = try s.file("victim.txt", "evil")
        try run("/usr/bin/tar", ["-cPf", s.path("absolute.tar").path, victim.path])
        try "original".write(to: victim, atomically: true, encoding: .utf8)
        // A symlink to a folder outside, then a file "through" it.
        let outside = try s.folder("outside")
        try s.folder("stage1"); try s.symlink("stage1/link", to: outside.path)
        try s.file("stage2/link/planted.txt", "evil")
        try run("/usr/bin/tar", ["-cf", s.path("symlink.tar").path, "-C", s.path("stage1").path, "link"])
        try run("/usr/bin/tar", ["-rf", s.path("symlink.tar").path, "-C", s.path("stage2").path, "link/planted.txt"])

        let cache = s.path("cache")
        // ".." and writing through a symlink are refused: the archive doesn't open.
        let dotdot = try await extract(s.path("dotdot.tar"), cache: cache)
        #expect(throws: (any Error).self) { try dotdot.get() }
        let symlink = try await extract(s.path("symlink.tar"), cache: cache)
        #expect(throws: (any Error).self) { try symlink.get() }
        // An absolute path loses its leading "/" and lands inside the copy.
        let absolute = try await extract(s.path("absolute.tar"), cache: cache).get()
        let inside = absolute.appendingPathComponent(String(victim.path.dropFirst()))
        #expect(try String(contentsOf: inside, encoding: .utf8) == "evil")
        #expect(try String(contentsOf: victim, encoding: .utf8) == "original")
        #expect(s.listing("outside").isEmpty)
        let escaped = try FileManager.default.subpathsOfDirectory(atPath: cache.path).filter { $0.hasSuffix("escaped.txt") }
        #expect(escaped.allSatisfy { $0.contains("/dotdot.tar/") })
    }
}

// MARK: Path completion, Trash, cloud state, icons

/// On the main actor: IconTheme is main-thread only, as in the app.
@MainActor @Suite struct SmallLocationTests {
    @Test func pathCompletionOffersFolders() throws {
        let s = try Scratch()
        try s.folder("Alpha"); try s.folder("alps"); try s.folder(".hidden"); try s.folder("beta")
        try s.file("alfa.txt")
        try s.symlink("alink", to: "Alpha")
        var c = CompletionSource()
        #expect(c.folders(in: s.url.path, matching: "al") == ["Alpha", "alink", "alps"])
        #expect(c.folders(in: s.url.path, matching: "AL") == ["Alpha", "alink", "alps"])
        #expect(c.folders(in: s.url.path, matching: "") == ["Alpha", "alink", "alps", "beta"])
        #expect(c.folders(in: s.url.path, matching: ".") == [".hidden"])
        #expect(c.folders(in: s.url.path, matching: "zz").isEmpty)
        // Another folder is listed afresh.
        try s.folder("Alpha/inner")
        #expect(c.folders(in: s.path("Alpha").path, matching: "") == ["inner"])
        #expect(c.folders(in: s.path("missing").path, matching: "").isEmpty)
    }

    @Test func trashSummary() throws {
        let s = try Scratch()
        let trash = try s.folder("Trash")
        #expect(TrashInfo.summary(of: trash) == "The Trash is empty.")
        try s.file("Trash/.DS_Store")
        #expect(TrashInfo.isEmpty(trash))
        #expect(TrashInfo.summary(of: trash) == "The Trash is empty.")
        try s.file("Trash/a.txt", String(repeating: "x", count: 10_000))
        try s.file("Trash/old folder/b.txt", "b")
        #expect(!TrashInfo.isEmpty(trash))
        let text = TrashInfo.summary(of: trash)
        #expect(text.hasPrefix("2 items in the Trash, ") && text.hasSuffix(" KiB."))
        #expect(TrashInfo.summary(of: s.path("unreadable")).contains("Full Disk Access"))
        #expect(TrashInfo.isEmpty(s.path("unreadable")))
        #expect(TrashInfo.folder.lastPathComponent == ".Trash")
    }

    @Test func localFilesHaveNoCloudBadge() throws {
        let s = try Scratch()
        let r = CloudState.of(try s.file("a"))
        #expect(r.state == .local && !r.isCloud)
        #expect(CloudState.of(URL(string: "sftp://host/a")!).isCloud == false)
        #expect(CloudState.local.symbol == nil && CloudState.local.help.isEmpty)
        for state in [CloudState.cloudOnly, .downloading, .uploading] {
            #expect(state.symbol != nil && !state.help.isEmpty)
        }
    }

    @Test func iconFiles() throws {
        let theme = IconTheme.shared
        #expect(theme.has("folder") && theme.has("user-home"))
        #expect(!theme.has("no-such-icon"))
        // Small sizes prefer the pixel-exact folder, large ones the scalable icon.
        let small = try #require(theme.file("folder", size: 16))
        #expect(small.path.hasSuffix("/16/places/folder.svg"))
        let large = try #require(theme.file("folder", size: 128))
        #expect(large.path.hasSuffix("/scalable/places/folder.svg"))
        // Only in 16: found for any size.
        #expect(theme.file("folder-pcloud", size: 128)?.lastPathComponent == "folder-pcloud.svg")
        #expect(theme.file("no-such-icon", size: 16) == nil)
        #expect(theme.file("no-such-icon", size: 16) == nil)  // cached miss
    }

    @Test func folderIcons() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(IconTheme.folderIconName(home) == "user-home")
        #expect(IconTheme.folderIconName(home.appendingPathComponent("Downloads")) == "folder-download")
        #expect(IconTheme.folderIconName(home.appendingPathComponent("Movies")) == "folder-videos")
        #expect(IconTheme.folderIconName(home.appendingPathComponent(".Trash")) == "user-trash")
        #expect(IconTheme.folderIconName(URL(fileURLWithPath: "/Applications")) == "folder-apple")
        #expect(IconTheme.folderIconName(URL(fileURLWithPath: "/")) == "drive-harddisk")
        #expect(IconTheme.folderIconName(URL(fileURLWithPath: "/Volumes/USB")) == "drive-removable-media")
        #expect(IconTheme.folderIconName(URL(fileURLWithPath: "/Volumes/USB/inside")) == "folder")
        #expect(IconTheme.folderIconName(home.appendingPathComponent("Documents/../Music")) == "folder-music")
    }
}

// MARK: Search

@MainActor @Suite struct SearchTests {
    /// Runs a search until it reports it is done.
    private func search(
        _ text: String, in scope: URL, contents: Bool = false, spotlight: Bool = true, spotlightTimeout: TimeInterval? = nil
    ) async throws -> [String] {
        var result: [FileItem]?
        let runner = SearchRunner(text: text, scope: scope, contents: contents) { items, done in if done { result = items } }
        if let spotlightTimeout { runner.gatheringTimeout = spotlightTimeout }
        runner.usesSpotlight = spotlight
        runner.start()
        defer { runner.stop() }
        try #require(await eventually(20) { result != nil })
        return (result ?? []).map(\.name).sorted()
    }

    /// The simple search, as for folders Spotlight doesn't index: hidden folders included, app bundles not entered.
    @Test func simpleSearchFindsNamesAndContents() async throws {
        let s = try Scratch()
        let tag = "porpoisefind\(UUID().uuidString.prefix(6))"
        try s.file("a/\(tag)-one.txt")
        try s.file("a/b/\(tag.uppercased())-two.md")
        try s.file(".hidden/\(tag)-three")
        try s.file("other.txt", "mentions \(tag) inside")
        try s.folder("App.app/Contents/\(tag)-packaged")
        #expect(try await search(tag, in: s.url, spotlight: false) == ["\(tag)-one.txt", "\(tag)-three", "\(tag.uppercased())-two.md"].sorted())
        #expect(try await search(tag, in: s.url, contents: true, spotlight: false).contains("other.txt"))
        #expect(try await search("nothing-matches-\(tag)", in: s.url, spotlight: false).isEmpty)
    }

    /// With Spotlight switched off (as on CI), a query never finishes gathering: the simple search takes over.
    @Test func whenSpotlightNeverAnswersTheSimpleSearchTakesOver() async throws {
        let s = try Scratch()
        let tag = "porpoiseslow\(UUID().uuidString.prefix(6))"
        try s.file("deep/down/\(tag).txt")
        #expect(try await search(tag, in: s.url, spotlightTimeout: 0) == ["\(tag).txt"])
    }

    @Test func spotlightQueries() throws {
        let runner = SearchRunner(text: "report", scope: URL(fileURLWithPath: "/tmp/nowhere-\(UUID().uuidString)"), contents: false) { _, _ in }
        runner.start()
        defer { runner.stop() }
        #expect(runner.query.predicate?.predicateFormat == #"kMDItemFSName LIKE[cd] "*report*""#)
        let both = SearchRunner(text: "x", scope: URL(fileURLWithPath: "/tmp"), contents: true) { _, _ in }
        both.start()
        defer { both.stop() }
        #expect(both.query.predicate?.predicateFormat == #"kMDItemTextContent LIKE[cd] "*x*" OR kMDItemFSName LIKE[cd] "*x*""#)
    }

    @Test func taggedFilesQuery() {
        let q = MetadataListQuery.tagged("Red") { _ in }
        #expect(q.query.predicate?.predicateFormat == #"kMDItemUserTags == "Red""#)
    }

    @Test func smartFolders() throws {
        let s = try Scratch()
        let saved = s.path("Big.savedSearch")
        let plist: NSDictionary = [
            "RawQuery": "(kMDItemFSSize > 1000000)",
            "SearchCriteria": ["FXScopeArrayOfPaths": ["kMDQueryScopeHome", s.url.path]],
        ]
        try #require(plist.write(to: saved, atomically: true))
        let q = try #require(MetadataListQuery.smartFolder(saved) { _ in })
        #expect(q.query.predicate != nil)
        #expect(q.query.searchScopes.count == 2)
        #expect(q.query.searchScopes.first as? String == NSMetadataQueryUserHomeScope)

        try "not a plist".write(to: saved, atomically: true, encoding: .utf8)
        #expect(MetadataListQuery.smartFolder(saved) { _ in } == nil)
    }
}

@MainActor @Suite(.isolatedSettings) struct VirtualLocationTests {
    @Test func unreadableSmartFolder() async throws {
        let s = try Scratch()
        let saved = try s.file("Broken.savedSearch", "garbage")
        var loads = 0
        let m = DirectoryModel(location: URL(string: "smart:" + saved.path)!)
        m.onLoaded = { loads += 1 }
        m.reload()
        #expect(loads == 1 && !m.isLoading)
        #expect(m.loadError == "This Smart Folder's search could not be read.")
        #expect(m.props.mode == .details && m.rows.isEmpty && m.isVirtual)
    }
}
