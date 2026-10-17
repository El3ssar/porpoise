import Foundation
import Testing

@testable import PorpoiseServices

/// The browser's page after signing in: who signed in or why it failed, self-contained, light and dark.
@Suite struct CloudOAuthPageTests {
    func fetch(_ loopback: CloudOAuthLoopback, then finish: (CloudOAuthLoopback) -> Void) async throws -> (String, HTTPURLResponse?) {
        let callback = URL(string: "\(loopback.redirectURL)?state=s&code=c")!
        let receiving = Task { try await loopback.callback() }
        let browser = Task { try await URLSession.shared.data(from: callback) }
        #expect(try await receiving.value == callback)
        finish(loopback)
        let (data, response) = try await browser.value
        return (String(decoding: data, as: UTF8.self), response as? HTTPURLResponse)
    }

    @Test func signedInSaysWhoAndNeedsNothingElse() async throws {
        let (page, response) = try await fetch(try CloudOAuthLoopback()) {
            $0.finish(.signedIn(provider: "Google Drive", account: "me@example.com"))
            $0.finish(.failed(provider: "Google Drive", reason: "ignored: answered once"))
        }
        #expect(response?.statusCode == 200 && response?.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
        #expect(response?.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("default-src 'none'") == true)
        #expect(page.contains("You’re signed in to Google Drive") && page.contains("<strong>me@example.com</strong>"))
        #expect(page.contains("You can close this tab") && !page.contains("ignored"))
        #expect(page.contains("prefers-color-scheme: dark") && page.contains("<svg class=\"icon\""))
        // No external resources: nothing to fetch, no scripts.
        #expect(!page.contains("src=") && !page.contains("<script") && !page.contains("url(http") && !page.contains("<link"))
    }

    @Test func failuresSayWhyAndCancellingStillAnswers() async throws {
        let (failed, _) = try await fetch(try CloudOAuthLoopback()) {
            $0.finish(.failed(provider: "Dropbox", reason: "Access was denied."))
        }
        #expect(failed.contains("Couldn’t sign in to Dropbox") && failed.contains("Access was denied.") && failed.contains("class=\"mark error\""))
        let (plain, _) = try await fetch(try CloudOAuthLoopback()) { $0.cancel() }
        #expect(plain.contains("Sign-in response received"))
    }

    @Test func namesAreEscaped() {
        let html = CloudOAuthPage.signedIn(provider: "Google Drive", account: "<script>alert(1)</script>&\"'").html
        #expect(!html.contains("<script>") && html.contains("&lt;script&gt;alert(1)&lt;/script&gt;&amp;&quot;&#39;"))
    }

    /// The inline icon is the app's: same shapes as Resources/AppIcon.svg.
    @Test func iconIsTheAppIcon() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let svg = try String(contentsOf: repo.appendingPathComponent("Resources/AppIcon.svg"), encoding: .utf8)
        let shapes = svg.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("<path") || $0.hasPrefix("<rect") || $0.hasPrefix("<stop") || $0.hasPrefix("<feDropShadow") }
        #expect(shapes.count >= 10)
        for shape in shapes { #expect(CloudOAuthPage.icon.contains(shape), "\(shape)") }
    }
}
