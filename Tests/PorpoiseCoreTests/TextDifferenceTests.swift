import Foundation
import Testing

@testable import PorpoiseCore

struct TextDifferenceTests {
    @Test func terminatorsAndEmptyFiles() {
        for (a, b) in [("", ""), ("a\r\nb\r\n", "a\nb\n"), ("a\n", "a"), ("", "x"), ("x", ""), ("😀\n", "🦊\n")] {
            reconstruct(a, b)
        }
        #expect(TextDifference.lines("a\r\nb\r\n") == ["a\r\n", "b\r\n"])
        #expect(TextDifference(left: "a\n", right: "a").changes.count == 1)
    }
    @Test func insertionDeletionAndRepeatedLines() {
        reconstruct("a\nb\na\nb\nc\n", "a\na\nx\nb\nc\n")
        reconstruct("a\nb\nc\n", "a\nx\nb\nc\n")
        reconstruct("a\nb\nc\n", "a\nc\n")
        #expect(TextDifference(left: "a\nb\nc\n", right: "a\nx\nc\n").changes == [TextChange(left: 1..<2, right: 1..<2)])
    }
    @Test func generatedReconstruction() {
        var seed: UInt64 = 42
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
        for _ in 0..<500 {
            let a = (0..<random(50)).map { _ in "\(random(8))\n" }.joined()
            let b = (0..<random(50)).map { _ in "\(random(8))\n" }.joined()
            reconstruct(a, b)
        }
    }
    @Test func boundedUnrelatedLargeInput() {
        reconstruct(String(repeating: "left\n", count: 10000), String(repeating: "right\n", count: 10000))
    }
    @Test func whitespaceAndUnicodeWords() {
        #expect(TextDifference(left: " a  b\n", right: "a b\n", ignoreWhitespace: true).changes.isEmpty)
        let spans = WordDifference.ranges("hello 🌍 old world", "hello 🌍 new world")
        #expect(("hello 🌍 old world" as NSString).substring(with: spans.left[0]) == "old")
        #expect(("hello 🌍 new world" as NSString).substring(with: spans.right[0]) == "new")
    }
    @Test func wordInsertionAtEndPreservesCommonWord() {
        let spans = WordDifference.ranges("hello", "hello world")
        #expect(spans.left.allSatisfy { $0.length == 0 })
        #expect(spans.right.map { ("hello world" as NSString).substring(with: $0) }.joined() == " world")
    }
    @Test func copyOneChange() {
        let d = TextDifference(left: "a\nold\nz\n", right: "a\nnew\nz\n")
        #expect(d.copying(0, toRight: true) == "a\nold\nz\n")
        #expect(d.copying(0, toRight: false) == "a\nnew\nz\n")
        #expect(d.copying(8, toRight: true) == nil)
    }
    private func reconstruct(_ a: String, _ b: String) {
        let d = TextDifference(left: a, right: b)
        var lines = d.left
        for c in d.changes.reversed() { lines.replaceSubrange(c.left, with: d.right[c.right]) }
        #expect(lines.joined() == b)
    }
}
