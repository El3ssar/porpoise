import XCTest

@testable import PorpoiseCore

final class AutomationDisplayTests: XCTestCase {
    func testControlAndDirectionalCharactersCannotSpoofPromptLabels() {
        let shown = AutomationDisplay.quotedPath("/tmp/日本語 🐬 'quote\"\\\n\t\r\u{202e}\u{2066}\u{2028}\u{2029}")
        XCTAssertTrue(shown.hasPrefix("\"/tmp/日本語 🐬 'quote\\\"\\\\\\n\\t\\r"))
        XCTAssertTrue(shown.hasSuffix("\\u{202e}\\u{2066}\\u{2028}\\u{2029}\""))
        XCTAssertFalse(shown.contains("\n") || shown.contains("\t") || shown.contains("\u{202e}") || shown.contains("\u{2066}"))
    }
    func testLiteralEscapeSequencesRemainDistinctFromControls() {
        XCTAssertNotEqual(AutomationDisplay.quotedPath("a\\n"), AutomationDisplay.quotedPath("a\n"))
        XCTAssertNotEqual(AutomationDisplay.quotedPath("a\\u{202e}"), AutomationDisplay.quotedPath("a\u{202e}"))
    }
}
