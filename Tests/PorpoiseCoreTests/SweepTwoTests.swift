import Foundation
import Testing

@testable import PorpoiseCore

/// Regressions found by the second codebase sweep (Core).
struct SweepTwoCoreTests {
    @Test func renameKeepsTheStemWhenAMarkFollowsTheDot() throws {
        let entry = BatchRenameEntry(url: URL(fileURLWithPath: "/x/a.\u{301}x"))
        #expect(try BatchRename.name(entry, index: 0, preset: BatchRenamePreset(name: "")) == "a.\u{301}x")
    }

    @Test func aTypedDotInANewExtensionIsNotDoubled() throws {
        let entry = BatchRenameEntry(url: URL(fileURLWithPath: "/x/photo.png"))
        #expect(try BatchRename.name(entry, index: 0, preset: BatchRenamePreset(name: "", extensionMode: .change(".jpg"))) == "photo.jpg")
        #expect(try BatchRename.name(entry, index: 0, preset: BatchRenamePreset(name: "", extensionMode: .change("jpg"))) == "photo.jpg")
    }

    @Test func appearanceFromAnOlderVersionKeepsWhatItHas() throws {
        // A field this version doesn't know is ignored; fields it lacks get their defaults; the rest is kept.
        let json = #"{"version":1,"themeName":"Nord","iconsSize":96,"futureField":true}"#
        let value = try JSONDecoder().decode(AppearancePreferences.self, from: Data(json.utf8))
        #expect(value.themeName == "Nord" && value.iconsSize == 96 && value.scrollback == AppearancePreferences().scrollback)
        try value.validate()
        // Round trip.
        let back = try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(value))
        #expect(back == value)
    }

    @Test func folderVariantsArePlainNames() throws {
        var p = AppearancePreferences()
        p.folderVariant = "blue-dark"
        try p.validate()
        for bad in ["../x", "/tmp/x", "", "a/b"] {
            p.folderVariant = bad
            #expect(throws: AppearanceError.self) { try p.validate() }
        }
    }
}
