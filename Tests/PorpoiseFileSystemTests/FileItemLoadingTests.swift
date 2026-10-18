import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct FileItemLoadingTests {
    let fm = FileManager.default

    private func load(_ url: URL) throws -> FileItem { try #require(FileItem.load(url)) }

    @Test func plainFile() throws {
        let s = try Scratch()
        let url = try s.file("notes.txt", "hello")
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let it = try load(url)
        #expect(it.name == "notes.txt" && !it.isDirectory && !it.isSymlink && !it.isHidden && !it.isPackage)
        #expect(it.size == 5 && it.fileExtension == "txt")
        #expect(it.contentType == "public.plain-text" && it.mimeType == "text/plain")
        #expect(it.posixPermissions == 0o640 && it.owner == NSUserName() && it.group != nil)
        #expect(it.isReadable && it.isWritable && it.linkDestination == nil)
        #expect(it.modificationDate != nil && it.creationDate != nil)
        #expect(!it.typeDescription.isEmpty && it.typeDescription.first!.isUppercase)
    }

    @Test func folder() throws {
        let s = try Scratch()
        let it = try load(s.folder("Stuff.d"))
        #expect(it.isDirectory && it.isBrowsableFolder && !it.isPackage)
        #expect(it.fileExtension == "" && it.typeDescription == "Folder" && it.mimeType == "inode/directory")
    }

    @Test func packagesAndApps() throws {
        let s = try Scratch()
        try s.file(
            "Mini.app/Contents/Info.plist",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleIdentifier</key><string>app.porpoise.tests.mini</string></dict></plist>
            """)
        let app = try load(s.path("Mini.app"))
        #expect(app.isDirectory && app.isPackage && app.isApplication && !app.isBrowsableFolder)
        #expect(app.fileExtension == "app")
        let bundle = try load(s.folder("Thing.bundle"))
        #expect(bundle.isPackage && !bundle.isApplication && !bundle.isBrowsableFolder)
    }

    @Test func symlinksReportTheirTarget() throws {
        let s = try Scratch()
        try s.file("target.txt", "12345678")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: s.folder("dir").path)
        let toFile = try load(s.symlink("file-link", to: "target.txt"))
        #expect(toFile.isSymlink && !toFile.isDirectory && toFile.size == 8)
        #expect(toFile.linkDestination == "target.txt" && toFile.contentType == "public.plain-text")
        let toFolder = try load(s.symlink("dir-link", to: s.path("dir").path))
        #expect(toFolder.isSymlink && toFolder.isBrowsableFolder)
        #expect(toFolder.linkDestination == s.path("dir").path)
        // The link's own permissions, not its target's.
        #expect(toFolder.posixPermissions == 0o755)
    }

    @Test func danglingLink() throws {
        let s = try Scratch()
        let it = try load(s.symlink("broken", to: "nowhere"))
        #expect(it.isSymlink && !it.isDirectory && it.linkDestination == "nowhere")
    }

    @Test func aliasFile() throws {
        let s = try Scratch()
        let target = try s.folder("Real")
        let alias = s.path("Real alias")
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)
        let it = try load(alias)
        #expect(it.isAliasFile && !it.isDirectory && !it.isSymlink)
    }

    @Test func hiddenItems() throws {
        let s = try Scratch()
        #expect(try load(s.file(".profile")).isHidden)
        let flagged = try s.file("flagged")
        var values = URLResourceValues()
        values.isHidden = true
        var u = flagged
        try u.setResourceValues(values)
        #expect(try load(flagged).isHidden)
        #expect(try !load(s.file("plain")).isHidden)
    }

    @Test func unreadableAndReadOnlyItems() throws {
        let s = try Scratch()
        let locked = try s.file("locked", "x")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let it = try load(locked)
        #expect(!it.isReadable && !it.isWritable && it.posixPermissions == 0)
        let readOnly = try s.file("ro", "x")
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        #expect(try load(readOnly).isReadable && !load(readOnly).isWritable)
        #expect(FileItem.load(s.path("missing")) == nil)
    }

    @Test func ownerNamesAreLookedUpOnce() {
        #expect(FileItem.userName(0) == "root")
        #expect(FileItem.userName(0) == "root")
        #expect(FileItem.groupName(0) == "wheel")
        // Unknown ids show as numbers.
        #expect(FileItem.userName(54321) == "54321")
        #expect(FileItem.groupName(54321) == "54321")
    }

    @Test func listingAFolder() throws {
        let s = try Scratch()
        try s.file("a"); try s.file(".b"); try s.folder("c")
        let names = try DirectoryLister.list(s.url).map(\.name).sorted()
        #expect(names == [".b", "a", "c"])
        #expect(DirectoryLister.childCount(s.url, includeHidden: false) == 2)
        #expect(DirectoryLister.childCount(s.url, includeHidden: true) == 3)
        #expect(DirectoryLister.childCount(s.path("missing"), includeHidden: true) == nil)
        #expect(throws: (any Error).self) { try DirectoryLister.list(s.path("missing")) }
    }

    /// A listing reads its entries' attributes along with it (one pass): the same items as reading each one alone.
    @Test func listingMatchesLoadingEachEntry() throws {
        let s = try Scratch()
        try s.file("notes.txt", "hello"); try s.file(".hidden"); try s.folder("Folder")
        try s.file("Mini.app/Contents/Info.plist"); try s.symlink("link", to: "notes.txt"); try s.symlink("folder link", to: "Folder")
        let readOnly = try s.file("read only.txt")
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        let listed = try DirectoryLister.list(s.url).sorted { $0.name < $1.name }
        let loaded = try fm.contentsOfDirectory(atPath: s.url.path).map { try load(s.url.appendingPathComponent($0)) }.sorted { $0.name < $1.name }
        #expect(listed.count == 7 && listed == loaded)
        // Through a symlink to the folder: the items keep the path as given.
        let viaLink = try DirectoryLister.list(s.path("folder link"))
        #expect(viaLink.isEmpty)
        let alias = try s.symlink("alias", to: ".")
        #expect(try DirectoryLister.list(alias).allSatisfy { $0.url.deletingLastPathComponent().lastPathComponent == "alias" })
    }

    /// A listing nobody waits for any more stops.
    @Test func aCancelledListingStops() throws {
        let s = try Scratch()
        try s.file("a"); try s.file("b")
        #expect(throws: CancellationError.self) { try DirectoryLister.list(s.url, cancelled: { true }) }
        #expect(try DirectoryLister.list(s.url, cancelled: { false }).count == 2)
    }
}
