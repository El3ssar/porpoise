import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@Suite struct AppleScriptEscapingTests {
    @Test func appleScriptLiterals() {
        #expect(Escaping.appleScriptString("plain") == "\"plain\"")
        #expect(Escaping.appleScriptString(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
        #expect(Escaping.appleScriptString("a\nb\tc\r\nd") == #""a\nb\tc\r\nd""#)
        // A quote can't end the literal early: every inner quote is preceded by a backslash.
        let lit = Escaping.appleScriptString(#"x" & do shell script "evil"#)
        #expect(!lit.dropFirst().dropLast().contains(where: { $0 == "\n" }))
        #expect(
            lit.dropFirst().dropLast().replacingOccurrences(of: "\\\\", with: "").replacingOccurrences(of: "\\\"", with: "").contains("\"") == false)
    }
}
