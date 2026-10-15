import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.isolatedSettings) struct FolderIconTests {
    @Test func specialFoldersAndEveryBundledSizeResolve() throws {
        let names = [
            "folder", "folder-documents", "folder-download", "folder-music", "folder-pictures", "folder-videos", "user-home", "user-desktop",
        ]
        for name in names { #expect(IconTheme.isFolderIcon(name)) }
        #expect(!IconTheme.isFolderIcon("drive-harddisk"))
        #expect(!IconTheme.isFolderIcon("text-x-generic"))
        for theme in ["Tela-circle"] + IconTheme.bundledThemes {
            Settings.shared.updateAppearance { $0.iconTheme = theme }
            for size in [16, 22, 32, 64, 128, 256] {
                let file = try #require(IconTheme.shared.file("folder", size: size))
                #expect(FileManager.default.fileExists(atPath: file.path))
                if theme != "Tela-circle" { #expect(file.path.contains("/themes/" + theme + "/")) }
            }
            let original = IconTheme.shared.file("folder", size: 64)
            Settings.shared.updateAppearance { $0.folderVariant = "red" }
            #expect(IconTheme.shared.file("folder", size: 64) == original)
        }
    }
}
