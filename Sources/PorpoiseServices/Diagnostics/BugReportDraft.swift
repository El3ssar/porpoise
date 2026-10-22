import Foundation

/// Help › Report a Bug: GitHub's bug form with the Porpoise and macOS versions filled in, and the reviewed
/// diagnostics the person can read and save to attach. Porpoise sends nothing itself: the browser shows the form,
/// which is submitted or not there.
public struct BugReportDraft: Sendable {
    public let identity: DiagnosticIdentity
    /// The exact bytes shown and saved (see DiagnosticStore: no paths, names, servers or accounts by schema).
    public let diagnostics: DiagnosticExport

    public init(store: DiagnosticStore, identity: DiagnosticIdentity = .current) throws {
        self.identity = identity
        diagnostics = try store.preview()
    }

    /// "Porpoise 0.10.0 (412) on macOS 15.4.1, arm64"
    public var summary: String {
        "Porpoise \(identity.version) (\(identity.build)) on macOS \(identity.osVersion), \(identity.architecture)"
    }

    /// The repository's bug form (.github/ISSUE_TEMPLATE/bug_report.yml), its required version fields prefilled by id.
    public func issueURL(repository: String) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "github.com"
        c.path = "/\(repository)/issues/new"
        c.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "version", value: "\(identity.version) (\(identity.build))"),
            URLQueryItem(name: "macos", value: "\(identity.osVersion) (\(identity.architecture))"),
        ]
        return c.url!
    }

    /// A name for the saved diagnostics that sorts by date and says what it is.
    public static func fileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "Porpoise Diagnostics \(f.string(from: date)).json"
    }
}
