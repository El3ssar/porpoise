import Foundation
import Testing

@testable import PorpoiseCore

@Suite struct CompactColumnsTests {
    @Test func everyColumnSharesOneWidthCappedByZoom() {
        // A very long name is capped: 24 characters at 16 pt, more as the icons grow.
        let small = CompactColumns.textWidth(widest: 2000, iconSize: 16, charWidth: 7, maxChars: 0, minimum: 80)
        let large = CompactColumns.textWidth(widest: 2000, iconSize: 128, charWidth: 7, maxChars: 0, minimum: 80)
        #expect(small == 168)
        #expect(large == 364)
        // Zooming never makes the cap smaller.
        let caps = stride(from: CGFloat(16), through: 256, by: 4).map {
            CompactColumns.textWidth(widest: 5000, iconSize: $0, charWidth: 7, maxChars: 0, minimum: 80)
        }
        #expect(caps == caps.sorted())
    }

    @Test func shortNamesKeepColumnsNarrow() {
        #expect(CompactColumns.textWidth(widest: 120.2, iconSize: 64, charWidth: 7, maxChars: 0, minimum: 80) == 121)
        #expect(CompactColumns.textWidth(widest: 20, iconSize: 64, charWidth: 7, maxChars: 0, minimum: 80) == 80)
    }

    @Test func maximumWidthSettingWins() {
        // Settings › Compact › Maximum width "Small" (10 characters) applies at every zoom level.
        for size in [CGFloat(16), 64, 256] {
            #expect(CompactColumns.textWidth(widest: 900, iconSize: size, charWidth: 8, maxChars: 10, minimum: 40) == 80)
        }
        #expect(CompactColumns.defaultChars(iconSize: 16) == 24 && CompactColumns.defaultChars(iconSize: 256) == 84)
    }
}
