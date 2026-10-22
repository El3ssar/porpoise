import Foundation
import Testing

@testable import PorpoiseServices

/// Help › Report a Bug carries the versions and the reviewed diagnostics, and nothing else.
struct BugReportDraftTests {
    private let identity = DiagnosticIdentity(version: "0.10.0", build: "412")

    @Test func formIsPrefilledWithTheVersionsOnly() throws {
        let draft = try BugReportDraft(store: DiagnosticStore(identity: identity), identity: identity)
        let url = draft.issueURL(repository: "El3ssar/porpoise")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https" && parts.host == "github.com" && parts.path == "/El3ssar/porpoise/issues/new")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["template"] == "bug_report.yml" && query["version"] == "0.10.0 (412)")
        #expect(query["macos"] == "\(identity.osVersion) (\(identity.architecture))" && query.count == 3)
        #expect(draft.summary == "Porpoise 0.10.0 (412) on macOS \(identity.osVersion), \(identity.architecture)")
    }

    @Test func diagnosticsAreTheStoresReviewedBytes() throws {
        let store = DiagnosticStore(identity: identity)
        let operation = DiagnosticCorrelation()
        store.record(
            .persistenceWriteFailed, error: CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/Users/me/secret.txt"]),
            correlation: operation)
        let draft = try BugReportDraft(store: store, identity: identity)
        #expect(draft.diagnostics.text.contains("persistence.write_failed") && draft.diagnostics.text.contains("permission"))
        #expect(!draft.diagnostics.text.contains("secret") && !draft.diagnostics.text.contains("/Users/"))
        // What is saved is what was shown, even if more happens afterwards.
        store.record(.recoveryStarted)
        #expect(!draft.diagnostics.text.contains("recovery.started"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-test-bugreport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(BugReportDraft.fileName())
        try draft.diagnostics.write(to: file)
        #expect(try Data(contentsOf: file) == draft.diagnostics.data)
    }

    @Test func savedNameSortsByDate() {
        let date = Date(timeIntervalSince1970: 1_792_700_000)
        let name = BugReportDraft.fileName(at: date)
        #expect(name.hasPrefix("Porpoise Diagnostics 20") && name.hasSuffix(".json") && !name.contains("/"))
        #expect(name.range(of: #"\d{4}-\d{2}-\d{2} \d{4}\.json$"#, options: .regularExpression) != nil)
    }
}
