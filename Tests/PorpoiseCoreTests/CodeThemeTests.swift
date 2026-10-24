import Foundation
import PorpoiseCore
import Testing

struct CodeThemeTests {
    @Test func oldAppearanceFilesDefaultToGitHubDarkAndChoicesRoundTrip() throws {
        let old = try JSONDecoder().decode(AppearancePreferences.self, from: Data(#"{"themeName":"Nord"}"#.utf8))
        #expect(old.themeName == "Nord" && old.codeTheme == .githubDark)
        let newer = try JSONDecoder().decode(
            AppearancePreferences.self, from: Data(#"{"themeName":"Nord","iconTheme":"Tela-circle","codeTheme":"future-theme"}"#.utf8))
        #expect(newer.codeTheme == .githubDark && newer.themeName == "Nord" && newer.iconTheme == "Tela-circle")
        #expect(AppearancePreferences().codeTheme == .githubDark)
        for theme in CodeTheme.allCases {
            var preferences = old
            preferences.codeTheme = theme
            #expect(try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
        }
    }

    @Test func explicitThemesAreIndependentOfAppAppearanceAndFollowResolvesBoth() {
        for dark in [true, false] {
            #expect(CodeTheme.githubDark.palette(darkAppearance: dark) == .dark)
            #expect(CodeTheme.githubLight.palette(darkAppearance: dark) == .light)
            #expect(CodeTheme.followAppearance.palette(darkAppearance: dark) == (dark ? .dark : .light))
        }
        let palette = CodePalette.dark
        #expect(palette.background.hex == "#0d1117" && palette.text.hex == "#e6edf3")
        #expect(palette.keyword.hex == "#ff7b72" && palette.string.hex == "#a5d6ff" && palette.comment.hex == "#8b949e")
        #expect(palette.function.hex == "#d2a8ff" && palette.constant.hex == "#79c0ff" && palette.type.hex == "#ffa657")
        #expect(palette.tag.hex == "#7ee787" && palette.deleted.hex == "#ffdcd7" && palette.inserted.hex == "#aff5b4")
    }

    @Test func functionConstantAndDiffScopesUseTheRequestedPalette() throws {
        let swift = "func greet(name: String) -> Bool { return true }\ngreet(name: \"🐬\")"
        let tokens = try SyntaxTokenizer.tokenize(swift, language: .swift).spans
        let ns = swift as NSString
        #expect(tokens.filter { $0.kind == .function }.map { ns.substring(with: $0.range) } == ["greet", "greet"])
        #expect(tokens.filter { $0.kind == .constant }.map { ns.substring(with: $0.range) } == ["true"])
        #expect(SyntaxLanguage.detect(filename: "change.patch") == .diff && SyntaxLanguage.detect(filename: "change.diff") == .diff)
        let patch = "--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n +context is not inserted\n\n"
        let diff = try SyntaxTokenizer.tokenize(patch, language: .diff).spans
        let patchText = patch as NSString
        #expect(diff.filter { $0.kind == .inserted }.map { patchText.substring(with: $0.range) } == ["+new"])
        #expect(diff.filter { $0.kind == .deleted }.map { patchText.substring(with: $0.range) } == ["-old"])
        #expect(diff.filter { $0.kind == .heading }.count == 3)
    }
}
