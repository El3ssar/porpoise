import Foundation
import Testing
import UniformTypeIdentifiers

@testable import PorpoiseCore

/// Cloud and remote listings mostly carry no type: the item gets the one its name implies, which picks its icon and Kind.
struct RemoteItemTypeTests {
    static let samples: [(name: String, type: UTType)] = [
        ("Report.pdf", .pdf), ("photo.JPG", .jpeg), ("clip.mp4", .mpeg4Movie), ("bundle.zip", .zip),
        ("README.md", UTType("net.daringfireball.markdown")!),
        ("main.swift", .swiftSource), ("letter.docx", UTType("org.openxmlformats.wordprocessingml.document")!),
        ("sheet.xlsx", UTType("org.openxmlformats.spreadsheetml.sheet")!), ("slides.pptx", UTType("org.openxmlformats.presentationml.presentation")!),
        ("song.mp3", .mp3), ("image.png", .png), ("notes.txt", .plainText), ("data.json", .json), ("page.html", .html),
        ("script.sh", .shellScript), ("disk.dmg", UTType("com.apple.disk-image-udif")!), ("archive.tar.gz", .gzip), ("icon.svg", .svg),
    ]

    @Test func untypedRemoteFilesTakeTheirExtensionsType() throws {
        let folder = try #require(URL(string: "dropbox://account/"))
        for (name, type) in Self.samples {
            let item = FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: false)
            #expect(item.utType == type, "\(name)")
            #expect(item.typeDescription != "\((name as NSString).pathExtension.uppercased()) file", "\(name)")
        }
    }

    @Test func untypedRemoteFoldersAreFolders() throws {
        let item = FileItem(url: try #require(URL(string: "box://account/folder/123")), name: "Projects.v2", isDirectory: true)
        #expect(item.contentType == UTType.folder.identifier && item.typeDescription == "Folder")
    }

    @Test func namesWithoutAKnownTypeStayUntyped() throws {
        let url = try #require(URL(string: "s3://bucket/key"))
        // No extension says nothing: Kind reads "File", as before.
        #expect(FileItem(url: url, name: "Makefile", isDirectory: false).contentType == nil)
        // An extension macOS doesn't know keeps a type of its own (dynamic), as a local file's does.
        #expect(FileItem(url: url, name: "x.porpoise-unknown-ext", isDirectory: false).utType?.isDynamic == true)
    }

    @Test func aGivenTypeWins() throws {
        let url = try #require(URL(string: "gdrive://account/id"))
        #expect(FileItem(url: url, name: "renamed.txt", isDirectory: false, contentType: UTType.pdf.identifier).utType == .pdf)
    }

    @Test func renamingToAnotherExtensionChangesTheType() throws {
        let item = FileItem(url: try #require(URL(string: "onedrive://a/i")), name: "a.txt", isDirectory: false)
        #expect(item.named("a.pdf").utType == .pdf)
        #expect(item.named("b.TXT").utType == .plainText)
        let doc = FileItem(url: try #require(URL(string: "gdrive://a/d")), name: "Doc", isDirectory: false, contentType: "com.google.apps.document")
        #expect(doc.named("Doc 2").contentType == "com.google.apps.document")
    }

    @Test func sftpAndFtpListingsTypeByName() throws {
        let folder = try #require(URL(string: "sftp://host/home/"))
        let items = RemoteParsing.parseLsLong(
            """
            drwxr-xr-x 2 u g 4096 Jan 1 2024 src
            -rw-r--r-- 1 u g 10 Jan 1 2024 main.swift
            -rw-r--r-- 1 u g 10 Jan 1 2024 movie.mp4
            """, folder: folder)
        #expect(items.map(\.contentType) == [UTType.folder.identifier, UTType.swiftSource.identifier, UTType.mpeg4Movie.identifier])
    }

    @Test func driveGenericMimeTypesYieldToTheName() {
        // What Drive sends for files it doesn't recognise, and for text of any kind.
        #expect(DriveFile(id: "s", name: "main.swift", mimeType: "application/octet-stream").contentType == UTType.swiftSource.identifier)
        #expect(DriveFile(id: "m", name: "README.md", mimeType: "text/plain").contentType == "net.daringfireball.markdown")
        #expect(DriveFile(id: "z", name: "x.zip", mimeType: "application/x-zip-compressed").contentType == UTType.zip.identifier)
        // A specific MIME type the name contradicts stays what Drive says.
        #expect(DriveFile(id: "j", name: "photo.txt", mimeType: "image/jpeg").contentType == UTType.jpeg.identifier)
        #expect(DriveFile(id: "p", name: "Untitled", mimeType: "application/pdf").contentType == UTType.pdf.identifier)
        #expect(DriveFile(id: "u", name: "blob", mimeType: "application/x-porpoise-unknown").contentType == UTType.data.identifier)
    }
}
