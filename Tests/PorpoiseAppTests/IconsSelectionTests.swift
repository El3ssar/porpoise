import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Icons view in the native theme selects as Finder does: a neutral backing behind the icon, so its colours stay
/// readable (a blue folder on a blue fill disappeared), and the accent behind the name only.
@Suite(.serialized, .isolatedSettings) @MainActor struct IconsSelectionTests {
    /// The sRGB colour at a point of the row's picture, in the view's (flipped) coordinates.
    private func color(_ image: CGImage, at p: CGPoint, in frame: CGRect) throws -> NSColor {
        let rep = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(image.width) / frame.width
        let x = Int((p.x - frame.minX) * scale), y = Int((p.y - frame.minY) * scale)
        return try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func isPink(_ c: NSColor) -> Bool { c.redComponent > 0.8 && c.greenComponent < 0.5 && c.blueComponent > 0.4 }

    @Test func theAccentIsBehindTheNameAndNotTheIcon() async throws {
        let s = try Scratch()
        try s.folder("Atlas")
        try s.file("notes.txt", "n")
        Tokens.accentOverride = NSColor(srgbRed: 1, green: 0.2, blue: 0.6, alpha: 1)
        defer { Tokens.accentOverride = nil }
        let model = try await DirectoryModel.loaded(s.url) { $0.props.mode = .icons }
        let list = ItemListView(model: model)
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        list.computeLayout()
        let i = try #require(model.index(of: s.path("Atlas")))
        model.selection = [s.path("Atlas")]
        #expect(Tokens.isNative)

        let frame = list.frames[i], backing = list.iconSelectionRect(i), pill = list.iconsNamePillRect(i)
        // Both inside the item, the pill below the backing and no wider than the item.
        #expect(frame.contains(backing) && frame.insetBy(dx: -1, dy: -1).contains(pill) && pill.minY >= backing.maxY - 1)
        #expect(backing.width >= list.iconRect(i).width && backing.midX == list.iconRect(i).midX)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var picture: CGImage?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { picture = list.picture(ofRow: i) }
            let image = try #require(picture)
            // The pill's edge (clear of the text) is the accent; the backing beside the icon is not.
            #expect(isPink(try color(image, at: CGPoint(x: pill.minX + 2, y: pill.midY), in: frame)))
            #expect(!isPink(try color(image, at: CGPoint(x: backing.minX + 1.5, y: backing.midY), in: frame)))
        }
    }
}
