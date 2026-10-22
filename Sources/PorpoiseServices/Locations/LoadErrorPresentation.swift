import Foundation

/// What an empty file list says: why nothing is shown and, for a failure, the one thing to do about it.
public struct ListState: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case retry, goUp, openPrivacySettings

        public var title: String {
            switch self {
            case .retry: "Try Again"
            case .goUp: "Go to Enclosing Folder"
            case .openPrivacySettings: "Open Privacy Settings…"
            }
        }
    }

    public var title: String
    public var message = ""
    /// The tool's or service's own words, for whoever needs them; never the headline.
    public var details: String?
    public var action: Action?
    public var isError = false
    /// The SF Symbol shown above a failure.
    public var symbol = "exclamationmark.triangle"

    public init(
        title: String, message: String = "", details: String? = nil, action: Action? = nil, isError: Bool = false,
        symbol: String = "exclamationmark.triangle"
    ) {
        self.title = title
        self.message = message
        self.details = details
        self.action = action
        self.isError = isError
        self.symbol = symbol
    }
}

/// Turns a listing's failure, worded by whichever tool or service produced it ("ssh: connect to host … port 22:
/// Connection refused", "request failed (HTTP 403)", "S3 error 403: AccessDenied"), into a sentence and an action.
public enum LoadErrorPresentation {
    /// A list with nothing in it that didn't fail: still loading, filtered or searched to nothing, or empty.
    public static func empty(loading: Bool, searching: Bool, searchError: String?, filtering: Bool, trash: Bool) -> ListState {
        if loading { return ListState(title: "Loading…") }
        if searching, let searchError {
            return ListState(title: "The search didn’t finish", message: searchError, isError: true)
        }
        if searching { return ListState(title: "No items match the search") }
        if filtering { return ListState(title: "No items match the filter") }
        return ListState(title: trash ? "Trash is empty" : "Folder is empty")
    }

    /// `missing`: a folder on this Mac that doesn't exist (checked by the caller). `cloud`: the account's own message
    /// says what happened and what to do, so only a short headline goes here.
    public static func error(_ raw: String, location: URL, missing: Bool, blockedByPrivacy: Bool, cloud: Bool) -> ListState {
        let name = location.lastPathComponent.isEmpty ? (location.host ?? location.absoluteString) : location.lastPathComponent
        if blockedByPrivacy {
            return ListState(
                title: "Porpoise needs Full Disk Access",
                message: "macOS protects this folder. Allow Full Disk Access for Porpoise "
                    + "in System Settings, then come back.", action: .openPrivacySettings, isError: true, symbol: "lock.shield")
        }
        if missing {
            return ListState(
                title: "Folder not found", message: "“\(name)” doesn’t exist. It may have been moved, renamed or deleted.", action: .goUp,
                isError: true, symbol: "folder.badge.questionmark")
        }
        if cloud { return ListState(title: "This folder isn’t available", action: .retry, isError: true) }
        if location.isFileURL {
            if raw == LocationLoadError.permission.message {
                return ListState(
                    title: "No access", message: "You don’t have permission to see what’s in “\(name)”.", action: .goUp, isError: true,
                    symbol: "lock")
            }
            return ListState(title: "Couldn’t open “\(name)”", message: plain(raw) ?? "", details: details(raw), action: .retry, isError: true)
        }
        let host = location.host ?? name
        let lower = raw.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }
        let connection: String?
        if has("connection refused") {
            connection = "\(host) refused the connection. Check that the server is running and the port is right."
        } else if has("could not resolve", "nodename nor servname", "unknown host", "name or service not known") {
            connection = "\(host) couldn’t be found. Check the server name and your network."
        } else if has("timed out", "timeout") {
            connection = "\(host) didn’t answer in time. Check your network, then try again."
        } else if has("network is unreachable", "no route to host", "not connected to the internet", "network connection was lost") {
            connection = "Your Mac can’t reach \(host) right now. Check your network connection."
        } else if has("host key verification failed", "remote host identification has changed") {
            connection = "\(host) no longer has the identity it had when you last connected, so Porpoise didn’t connect."
        } else {
            connection = nil
        }
        if let connection {
            return ListState(
                title: "Couldn’t connect to \(host)", message: connection, details: raw, action: .retry, isError: true, symbol: "network.slash")
        }
        let message: String
        if has("permission denied (publickey", "authentication failed", "login incorrect", "http 401", "error 401") {
            message = "\(host) didn’t accept the sign-in. Check the user name, password or key."
        } else if has("http 403", "error 403", "accessdenied", "access denied") {
            message = "You don’t have access to this folder on \(host)."
        } else if has("http 404", "error 404", "nosuchkey", "nosuchbucket", "no such file") {
            message = "This folder doesn’t exist on \(host). It may have been moved or deleted."
        } else if lower.range(of: #"(http|error) 5\d\d"#, options: .regularExpression) != nil {
            message = "\(host) had a problem answering. Try again in a moment."
        } else {
            message = plain(raw) ?? "Porpoise couldn’t list this folder on \(host)."
        }
        return ListState(title: "Couldn’t open “\(name)”", message: message, details: details(raw), action: .retry, isError: true)
    }

    /// The text itself when it already reads as a sentence: no exit statuses, error codes or file paths.
    static func plain(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 160, !text.contains("/"),
            text.range(of: #"\(-?\d+\)|\berror -?\d+|\b\d{3}\b|:\s*\S+:"#, options: .regularExpression) == nil
        else { return nil }
        return text
    }

    /// The raw text, kept only when the message doesn't already say it.
    private static func details(_ raw: String) -> String? { plain(raw) == nil && !raw.isEmpty ? raw : nil }
}
