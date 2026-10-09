import Foundation
import Testing
@testable import PorpoiseCore

@Suite(.serialized) struct EscapingTests {
    @Test func appleScriptLiterals() {
        #expect(Escaping.appleScriptString("plain") == "\"plain\"")
        #expect(Escaping.appleScriptString(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
        #expect(Escaping.appleScriptString("a\nb\tc\r\nd") == #""a\nb\tc\r\nd""#)
        // A quote can't end the literal early: every inner quote is preceded by a backslash.
        let lit = Escaping.appleScriptString(#"x" & do shell script "evil"#)
        #expect(!lit.dropFirst().dropLast().contains(where: { $0 == "\n" }))
        #expect(lit.dropFirst().dropLast().replacingOccurrences(of: "\\\\", with: "").replacingOccurrences(of: "\\\"", with: "").contains("\"") == false)
    }

    // MARK: Preview server paths

    private let fm = FileManager.default
    private let secret = "S3CRET"

    /// root/stream/index.m3u8, a secret file next to root, and symlinks inside root pointing in and out.
    private func setup() throws -> (base: URL, root: URL) {
        let base = fm.temporaryDirectory.appendingPathComponent("dolphin-serve-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("root")
        try fm.createDirectory(at: root.appendingPathComponent("stream"), withIntermediateDirectories: true)
        try Data("#EXTM3U".utf8).write(to: root.appendingPathComponent("stream/index.m3u8"))
        try Data("x".utf8).write(to: root.appendingPathComponent("stream/seg 1.m4s"))
        try Data("private".utf8).write(to: base.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("stream/out"), withDestinationURL: base.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("stream/in"), withDestinationURL: root.appendingPathComponent("stream/index.m3u8"))
        return (base, root.resolvingSymlinksInPath())
    }

    @Test func servesFilesInsideTheRoot() throws {
        let (base, root) = try setup(); defer { try? fm.removeItem(at: base) }
        #expect(Escaping.servedFile(for: "/S3CRET/stream/index.m3u8", root: root, secret: secret)?.lastPathComponent == "index.m3u8")
        #expect(Escaping.servedFile(for: "/S3CRET/stream/seg%201.m4s?t=1", root: root, secret: secret)?.lastPathComponent == "seg 1.m4s")
        #expect(Escaping.servedFile(for: "/S3CRET//stream//index.m3u8", root: root, secret: secret) != nil)
        #expect(Escaping.servedFile(for: "/S3CRET/stream/in", root: root, secret: secret) != nil)   // symlink staying inside
    }

    @Test func refusesEverythingElse() throws {
        let (base, root) = try setup(); defer { try? fm.removeItem(at: base) }
        let bad = [
            "/stream/index.m3u8",                    // no secret
            "/WRONG/stream/index.m3u8",
            "/S3CRET/../secret.txt",
            "/S3CRET/stream/../../secret.txt",
            "/S3CRET/%2e%2e/secret.txt",             // percent-encoded ..
            "/S3CRET/stream%2F..%2F..%2Fsecret.txt",  // encoded slashes
            "/S3CRET/%252e%252e/secret.txt",         // double encoding stays literal (and missing)
            "/S3CRET/stream/out",                    // symlink leading out of the root
            "/S3CRET/stream",                        // a folder
            "/S3CRET/",
            "/S3CRET/stream/index.m3u8%00.jpg",
            "/S3CRET/stream/..\\..\\secret.txt",
            "/S3CRET/stream/%ZZ",                    // invalid encoding
            "",
        ]
        for target in bad {
            #expect(Escaping.servedFile(for: target, root: root, secret: secret) == nil, "\(target)")
        }
    }
}
