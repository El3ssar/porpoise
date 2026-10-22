import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The events recorded at the app's error sites: their kind and category only. Each test feeds the site personal
/// data (user and file names, a token, an account id, a helper's paths) and checks none of it reaches the export.
@MainActor @Suite(.isolatedSettings, .serialized)
struct DiagnosticsInstrumentationTests {
    /// Whatever text in `export` looks personal (nothing, when the schema holds).
    private func personal(_ export: String, _ secrets: [String]) -> [String] {
        (secrets + [NSUserName(), NSHomeDirectory()]).filter { !$0.isEmpty && export.localizedCaseInsensitiveContains($0) }
    }

    @Test func aFailedCopyRecordsItsCategoryOnly() async throws {
        let s = try Scratch("alice-private")
        let src = try s.file("Tax Return Alice 2026.pdf", "private")
        let dst = try s.folder("Destination Alice")
        let c = makeController(ScriptedUI())
        c.history = OperationHistory(file: s.path("history.jsonl"))
        // The source goes before the job reads it: a failure that isn't a permission problem.
        c.prepareJob = { _ in try? FileManager.default.removeItem(at: src) }
        Diagnostics.shared.clear()
        c.run(.copy, [src], to: dst, window: nil)
        let activity = try #require(c.activities.last)
        #expect(await poll { activity.state.isEnded })
        #expect(!activity.errors.isEmpty)
        let text = try Diagnostics.shared.preview().text
        #expect(text.contains("\"transfer.failed\""))
        #expect(personal(text, ["Tax Return", "Alice", s.url.path, "private"]).isEmpty, "\(text)")
    }

    @Test func providerErrorsRecordWhenTheirCategoryChanges() throws {
        let store = DiagnosticStore()
        let status = CloudAccountStatus()
        status.diagnostics = store
        let id = UUID()
        status.track(id)
        let url = try #require(URL(string: "https://alice%40example.com:hunter2@api.example.com/Personal/Taxes.pdf?access_token=SECRET123"))
        let offline = URLError(
            .notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: url, NSLocalizedDescriptionKey: "Taxes.pdf for alice failed"])
        status.record(id, offline)
        status.record(id, offline)  // the same again: no new event
        status.record(id, nil)  // a success resets it
        status.record(id, offline)
        status.record(id, URLError(.cancelled))  // the user's own cancel: no event
        status.record(id, offline, signInNeeded: true)
        let text = try store.preview().text
        #expect(text.components(separatedBy: "\"provider.error\"").count - 1 == 3)
        #expect(text.contains("\"network\"") && text.contains("\"authentication\""))
        #expect(personal(text, ["alice", "hunter2", "SECRET123", "Taxes", "example.com", id.uuidString]).isEmpty, "\(text)")
    }

    @Test func helperFailuresRecordTheirKindOnly() throws {
        let store = DiagnosticStore()
        _ = PrivilegedHelper.diagnosed(.failed("chown: /Users/alice/Secret Project: Operation not permitted"), store: store)
        _ = PrivilegedHelper.diagnosed(.unavailable("Porpoise's helper didn't answer."), store: store)
        _ = PrivilegedHelper.diagnosed(.done, store: store)
        let text = try store.preview().text
        #expect(text.contains("\"helper.failed\"") && text.contains("\"helper.unavailable\""))
        #expect(text.components(separatedBy: "\"code\"").count - 1 == 2)
        #expect(personal(text, ["alice", "Secret Project", "chown", "Operation not permitted"]).isEmpty, "\(text)")
    }

    @Test func anUncleanExitIsRecordedOnTheNextLaunch() throws {
        let first = DiagnosticStore(), second = DiagnosticStore(), third = DiagnosticStore()
        Diagnostics.launched(store: first)  // a first launch: nothing to report
        #expect(!(try first.preview().text.contains("app.unclean_exit")))
        Diagnostics.launched(store: second)  // the first one never quit
        #expect(try second.preview().text.contains("\"app.unclean_exit\""))
        Diagnostics.quitting()
        Diagnostics.launched(store: third)  // after a normal quit
        #expect(!(try third.preview().text.contains("app.unclean_exit")))
    }
}
