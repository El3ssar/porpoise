import Foundation
import Testing

@testable import PorpoiseCore

struct DriveModelsTests {
    @Test func stableIdentityAndNavigation() throws {
        let accountID = UUID()
        for collection: DriveLocation.Collection in [.myDrive, .sharedWithMe, .sharedDrives, .folder("opaque-id", driveID: "drive-id")] {
            let location = DriveLocation(accountID: accountID, collection: collection, resourceKey: "key")
            let parsed = try #require(DriveLocation(url: location.url))
            #expect(parsed.accountID == accountID)
            #expect(parsed.collection == collection)
            #expect(parsed.resourceKey == "key")
            #expect(!location.title.isEmpty)
        }
        let root = DriveLocation(accountID: accountID)
        var file = DriveFile(id: "folder-one", name: "Old", mimeType: "application/vnd.google-apps.folder")
        let before = file.childLocation(in: root).url
        file.name = "Renamed"
        #expect(file.childLocation(in: root).url == before)
        #expect(before.deletingLastPathComponent() == root.url)
        let child = DriveFile(id: "nested-two", name: "Nested", mimeType: "application/vnd.google-apps.folder").childLocation(
            in: try #require(DriveLocation(url: before)))
        #expect(child.url.deletingLastPathComponent() == before)
        #expect(DriveLocation(url: child.url)?.collection == .folder("nested-two"))
        let shared = URL(string: "gdrive://\(accountID)/shared-drives/drive-id/child-id")!
        #expect(DriveLocation(url: shared)?.collection == .folder("child-id", driveID: "drive-id"))
        for bad in [
            "gdrive://invalid/my-drive", "https://host/my-drive", "gdrive://\(accountID)/folder", "gdrive://\(accountID)/wat/x",
            "gdrive://user@\(accountID)/my-drive", "gdrive://\(accountID)/folder/a%2Fb",
        ] {
            #expect(DriveLocation(url: URL(string: bad)!) == nil)
        }
    }

    @Test func trustedLinksAndResourceKeys() throws {
        for (text, id, folder) in [
            ("https://drive.google.com/drive/u/0/folders/abc_DEF-123?resourcekey=key-123", "abc_DEF-123", true),
            ("https://drive.google.com/file/d/file-id/view", "file-id", false),
            ("https://docs.google.com/document/d/doc-id/edit", "doc-id", false),
            ("https://drive.google.com/open?id=legacy-id", "legacy-id", false),
            ("https://drive.google.com/uc?id=download-id", "download-id", false),
        ] {
            let link = try #require(DriveLink(url: URL(string: text)!))
            #expect(link.itemID == id && link.isFolder == folder)
            #expect(link.location(accountID: UUID()).resourceKey == link.resourceKey)
        }
        #expect(DriveLink(url: URL(string: "https://drive.google.com/drive/folders/a?resourcekey=k")!)?.resourceKey == "k")
        for bad in [
            "http://drive.google.com/drive/folders/a", "https://drive.google.com.evil.invalid/drive/folders/a",
            "https://drive.google.com@evil.invalid/drive/folders/a", "https://drive.google.com/drive/folders/a%2Fb",
            "https://drive.google.com/drive/folders/", "https://drive.google.com/", "https://docs.google.com/open?id=x",
        ] {
            #expect(DriveLink(url: URL(string: bad)!) == nil)
        }
    }

    @Test func exportsAndReadOnlyMetadata() throws {
        for preset in DriveExportPreset.allCases {
            for kind in ["document", "spreadsheet", "presentation", "drawing"] {
                #expect(preset.format(for: "application/vnd.google-apps.\(kind)") != nil)
            }
            #expect(preset.format(for: "application/vnd.google-apps.form") == nil)
            #expect(preset.format(for: "text/plain") == nil)
        }
        #expect(DriveExportPreset.office.format(for: "application/vnd.google-apps.document")?.fileExtension == "docx")
        #expect(DriveExportPreset.office.format(for: "application/vnd.google-apps.spreadsheet")?.fileExtension == "xlsx")
        let json =
            #"{"id":"doc","name":"Notes","mimeType":"application/vnd.google-apps.document","owners":[{"emailAddress":"owner@example.invalid"}],"size":"12","modifiedTime":"2026-10-16T10:00:00Z","webViewLink":"https://docs.google.com/document/d/doc/edit"}"#
        let doc = try JSONDecoder().decode(DriveFile.self, from: Data(json.utf8))
        #expect(doc.operations.canExport && doc.operations.canOpenInBrowser)
        #expect(!doc.operations.canWrite && !doc.operations.canRename && !doc.operations.canTrash && !doc.operations.canBrowse)
        let item = doc.fileItem(accountID: UUID())
        #expect(!item.isWritable && item.isReadable && item.size == 12 && item.owner == "owner@example.invalid")
        #expect(item.modificationDate != nil)
        let binary = DriveFile(id: "bin", name: "Binary", mimeType: "text/plain")
        #expect(binary.operations.canDownload && !binary.operations.canExport)
        let folder = DriveFile(id: "folder", name: "Folder", mimeType: "application/vnd.google-apps.folder")
        #expect(folder.operations.canBrowse && !folder.operations.canDownload)
    }
}
