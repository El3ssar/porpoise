import Foundation
import PorpoiseServicesTestSupport
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

    @Test func aSpecialFolderDrawnOnlySmallIsUpscaledWhenLarge() {
        Settings.shared.updateAppearance { $0.iconTheme = "Tela-circle" }
        // Tela has the Applications folder only as a 16 px Apple glyph.
        #expect(IconTheme.shared.isUpscaled("folder-apple", size: 96))
        #expect(IconTheme.shared.isUpscaled("folder-apple", size: 22))
        #expect(!IconTheme.shared.isUpscaled("folder-apple", size: 16))
        // Scalable artwork never is.
        for name in ["folder", "user-home", "folder-documents"] { #expect(!IconTheme.shared.isUpscaled(name, size: 96)) }
        #expect(!IconTheme.shared.isUpscaled("no-such-icon", size: 96))
        #expect(IconTheme.folderIconName(URL(fileURLWithPath: "/Applications")) == "folder-apple")
    }
}
