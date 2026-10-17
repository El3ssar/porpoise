import Foundation
import Testing

@testable import PorpoiseCore

struct SearchSpecTests {
    @Test func foldedAndTermsAndMetadataApplyTogether() throws {
        let spec = try SearchSpec("CAFÉ report ext:pdf path:reports size:>=10 file: dm:>=2026-01-01")
        #expect(spec.nameMatches("CafE annual REPORT.pdf"))
        #expect(!spec.nameMatches("Cafe.pdf"))
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(spec.metadataMatches(path: "/Reports/cafe report.PDF", isDirectory: false, size: 12, modified: modified))
        #expect(!spec.metadataMatches(path: "/Reports/cafe report.txt", isDirectory: false, size: 12, modified: modified))
        #expect(!spec.metadataMatches(path: "/other/cafe report.pdf", isDirectory: false, size: 12, modified: modified))
        #expect(!spec.metadataMatches(path: "/Reports/cafe report.pdf", isDirectory: true, size: 12, modified: modified))
        #expect(!spec.metadataMatches(path: "/Reports/cafe report.pdf", isDirectory: false, size: 9, modified: modified))
        #expect(!spec.metadataMatches(path: "/Reports/cafe report.pdf", isDirectory: false, size: 12, modified: nil))
        #expect(!spec.supportsSpotlight)
    }

    @Test func contentQueriesKeepOperatorsAndSpacesLiteral() throws {
        let spec = try SearchSpec("ext:pdf café", contents: true)
        #expect(spec.query.extensions.isEmpty && spec.nameMatches("EXT:PDF CAFE.txt"))
        #expect(spec.contentMatches("literal EXT:PDF CAFE inside") && !spec.contentMatches("pdf cafe"))
        #expect(try SearchSpec("foo:bar").nameMatches("my FOO:BAR.txt"))
        #expect(try SearchSpec("\"annual report\"").nameMatches("annual report.pdf"))
        #expect(try SearchSpec("café report").supportsSpotlight)
        #expect(try !SearchSpec("a+b(1").nameMatches("ab1"))
        #expect(try !SearchSpec("a*b").supportsSpotlight)
    }

    @Test func boundsFoldersRegexAndNoExtensionMatchIndexRules() throws {
        let spec = try SearchSpec("folder: size:<=20 dm:<2026-01-01 regex:^caf")
        #expect(spec.nameMatches("Café") && !spec.nameMatches("decaf"))
        #expect(spec.metadataMatches(path: "/Cafe", isDirectory: true, size: 20, modified: nil))
        #expect(!spec.metadataMatches(path: "/Cafe", isDirectory: true, size: 21, modified: nil))
        #expect(!spec.metadataMatches(path: "/Cafe", isDirectory: true, size: 20, modified: .distantFuture))
        let noExtension = try SearchSpec("ext:.")
        #expect(noExtension.metadataMatches(path: "/.bashrc", isDirectory: false, size: 1, modified: nil))
        #expect(throws: IndexQuery.Invalid.self) { try SearchSpec("ext:") }
    }
}
