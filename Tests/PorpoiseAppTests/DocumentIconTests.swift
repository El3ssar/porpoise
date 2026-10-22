import AppKit
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized) @MainActor struct DocumentIconTests {
    init() { _ = NSApplication.shared }

    /// A 64 px "document": white paper from x 8–56, y 4–60, nothing around it.
    private func paper() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
            NSColor.white.setFill()
            CGRect(x: 8, y: 4, width: 48, height: 56).fill()
            return true
        }
    }

    private func pixels(_ image: NSImage) throws -> NSBitmapImageRep {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @Test func darkPaperIsDimmedAndLightPaperGetsAnEdge() throws {
        let dark = try pixels(Icons.documentImage(paper(), size: 64, dark: true))
        let middle = try #require(dark.colorAt(x: 32, y: 32)?.usingColorSpace(.sRGB))
        #expect(middle.redComponent <= 0.85 && middle.redComponent >= 0.75)
        // Dimming stays on the artwork: around it is still clear.
        #expect((dark.colorAt(x: 2, y: 32)?.alphaComponent ?? 1) == 0)

        let light = try pixels(Icons.documentImage(paper(), size: 64, dark: false))
        #expect((light.colorAt(x: 32, y: 32)?.usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.99)
        // Just outside the paper's left edge, the soft edge shows (rows are top-down: the paper spans y 4–60).
        #expect((light.colorAt(x: 7, y: 32)?.alphaComponent ?? 0) > 0)
    }

    @Test func changedWordsStandOutMoreInLight() {
        #expect(FileDiffTextView.wordTintAlpha(dark: false) > FileDiffTextView.wordTintAlpha(dark: true))
        #expect(FileDiffTextView.wordTintAlpha(dark: true) == 0.26)
    }
}
