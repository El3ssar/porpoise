import Foundation
import PorpoiseCore
import Testing

/// This process's own signature: a test binary is signed ad hoc by the linker (no certificate), so it has no leaf
/// certificate and no requirement can be built from it; a certificate-signed build gets a SHA-1 and a requirement.

/// Konsole color schemes as shipped and as written by hand.
@Suite struct KonsoleSchemeCoverageTests {
    @Test func theShippedDesertSchemeParsesCompletely() throws {
        // `swift test` runs in the package folder, where the shipped file is.
        let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Desert-Konsole.colorscheme")
        let parsed = KonsoleScheme.parse(try String(contentsOf: file, encoding: .utf8))
        #expect(parsed.palette.count == 16)
        #expect(parsed.background != nil && parsed.foreground != nil)
    }

    @Test func aCompleteSchemeReplacesTheBuiltInPalette() {
        var text = "[General]\nDescription=Test\n"
        for i in 0..<8 {
            text += "[Color\(i)]\nColor=\(i),\(i),\(i)\n\n"
            text += "[Color\(i)Intense]\n  Color=\(100 + i),\(100 + i), \(100 + i)\n"
        }
        text += "[Background]\nColor=1,2,3\n[Foreground]\nColor=4,5,6\n"
        let s = KonsoleScheme.parse(text)
        #expect(s.palette.map { $0.0 } == Array(0..<8) + Array(100..<108))
        #expect(s.background.map { [$0.0, $0.1, $0.2] } == [1, 2, 3])
        #expect(s.foreground.map { [$0.0, $0.1, $0.2] } == [4, 5, 6])
    }

    @Test func windowsLineEndingsAreRead() {
        // "\r\n" is one Character: split(separator: "\n") left the whole file as one line, and nothing was read.
        var text = "[General]\r\n"
        for i in 0..<8 { text += "[Color\(i)]\r\nColor=\(i),0,0\r\n[Color\(i)Intense]\r\nColor=\(100 + i),0,0\r\n" }
        let s = KonsoleScheme.parse(text + "[Background]\r\nColor=1,2,3\r\n")
        #expect(s.palette.map { $0.0 } == Array(0..<8) + Array(100..<108))
        #expect(s.background.map { [$0.0, $0.1, $0.2] } == [1, 2, 3])
    }

    @Test func anIncompleteSchemeKeepsTheBuiltInPalette() {
        let s = KonsoleScheme.parse("[Color0]\nColor=9,9,9\n[Color1]\nColor=1,2\n[Background]\nColor=x,y,z\n")
        #expect(s.palette.map { [$0.0, $0.1, $0.2] } == KonsoleScheme.builtInDesertPalette.map { [$0.0, $0.1, $0.2] })
        #expect(s.background == nil && s.foreground == nil)
    }

    @Test func theLightSchemeIsDarkOnLight() throws {
        let light = KonsoleScheme.light
        #expect(light.palette.count == 16)
        let bg = try #require(light.background), fg = try #require(light.foreground)
        #expect(bg.0 + bg.1 + bg.2 > fg.0 + fg.1 + fg.2)
    }
}
