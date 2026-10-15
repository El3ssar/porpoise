import Testing

@testable import PorpoiseCore

struct FolderColorTests {
    @Test func allColourWellExtremesRetainShading() {
        let targets = [
            ThemeColor(0, 0, 0), ThemeColor(255, 255, 255), ThemeColor(255, 255, 0),
            ThemeColor(255, 0, 0), ThemeColor(0, 255, 0), ThemeColor(0, 0, 255), ThemeColor(255, 220, 245),
        ]
        for target in targets {
            let shadow = FolderColor.map(ThemeColor(30, 85, 150), to: target)
            let highlight = FolderColor.map(ThemeColor(125, 190, 245), to: target)
            #expect(shadow != highlight)
            #expect(shadow.red + shadow.green + shadow.blue < highlight.red + highlight.green + highlight.blue)
            #expect(highlight != ThemeColor(255, 255, 255))
            #expect(shadow != ThemeColor(0, 0, 0))
        }
    }
    @Test func neutralEmblemsStayReadable() {
        for c in [ThemeColor(255, 255, 255), ThemeColor(150, 150, 150)] {
            #expect(FolderColor.map(c, to: ThemeColor(255, 0, 0)) == c)
            #expect(FolderColor.map(c, to: ThemeColor(255, 0, 0), monochrome: true) != c)
        }
    }
    @Test func darkShadowsGainTheFolderHue() {
        let mapped = FolderColor.map(ThemeColor(0, 0, 0), to: ThemeColor(255, 80, 80))
        #expect(mapped.red > mapped.green && mapped.red > mapped.blue)
        #expect(mapped.red < 150)
    }
    @Test func presetsAndCustomColoursShareOneMapping() {
        let custom = ThemeColor(24, 78, 132)
        #expect(FolderColor.tint(custom, variant: "default") == custom)
        #expect(FolderColor.tint(custom, variant: "future") == custom)
        for name in ["blue", "green", "red", "orange", "yellow", "purple", "pink", "grey"] {
            #expect(FolderColor.tint(custom, variant: name) != custom)
        }
    }
}
