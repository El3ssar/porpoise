import Foundation
import Testing

@testable import PorpoiseServices

/// A listing's failure, in whatever words its tool or service used, reads as a sentence with one thing to do.
struct LoadErrorPresentationTests {
    private let local = URL(fileURLWithPath: "/Users/someone/Projects")
    private let sftp = URL(string: "sftp://me@files.example.com/srv/data")!

    private func remote(_ raw: String, _ url: URL? = nil) -> ListState {
        LoadErrorPresentation.error(raw, location: url ?? sftp, missing: false, blockedByPrivacy: false, cloud: false)
    }

    @Test func emptyListsSayWhyQuietly() {
        func empty(loading: Bool = false, searching: Bool = false, error: String? = nil, filtering: Bool = false, trash: Bool = false)
            -> ListState
        {
            LoadErrorPresentation.empty(loading: loading, searching: searching, searchError: error, filtering: filtering, trash: trash)
        }
        #expect(empty(loading: true, searching: true).title == "Loading…")
        #expect(empty(searching: true) == ListState(title: "No items match the search"))
        let failed = empty(searching: true, error: "The index is being rebuilt.")
        #expect(failed.isError && failed.title == "The search didn’t finish" && failed.message == "The index is being rebuilt.")
        #expect(empty(filtering: true).title == "No items match the filter")
        #expect(empty(trash: true).title == "Trash is empty" && empty().title == "Folder is empty")
        #expect(!empty().isError && empty().action == nil)
    }

    @Test func folderProblemsOnThisMacOfferAWayOut() {
        let privacy = LoadErrorPresentation.error("x", location: local, missing: false, blockedByPrivacy: true, cloud: false)
        #expect(privacy.action == .openPrivacySettings && privacy.isError && privacy.title.contains("Full Disk Access"))
        let missing = LoadErrorPresentation.error("Could not open “Projects”.", location: local, missing: true, blockedByPrivacy: false, cloud: false)
        #expect(missing.title == "Folder not found" && missing.message.contains("“Projects” doesn’t exist") && missing.action == .goUp)
        let denied = LoadErrorPresentation.error(
            LocationLoadError.permission.message, location: local, missing: false, blockedByPrivacy: false, cloud: false)
        #expect(denied.title == "No access" && denied.action == .goUp && denied.details == nil)
        #expect(denied.symbol == "lock" && missing.symbol.hasPrefix("folder") && privacy.symbol == "lock.shield")
        let other = LoadErrorPresentation.error("Could not open “Projects”.", location: local, missing: false, blockedByPrivacy: false, cloud: false)
        #expect(other.title == "Couldn’t open “Projects”" && other.message == "Could not open “Projects”." && other.action == .retry)
        #expect(other.details == nil)
    }

    @Test func cloudFoldersLeaveTheExplanationToTheirAccountMessage() {
        let drive = URL(string: "gdrive://account/folder")!
        let state = LoadErrorPresentation.error("request failed (HTTP 500)", location: drive, missing: false, blockedByPrivacy: false, cloud: true)
        #expect(state == ListState(title: "This folder isn’t available", action: .retry, isError: true))
    }

    @Test func connectionFailuresNameTheHostAndKeepTheToolsWords() {
        let refused = remote("ssh: connect to host files.example.com port 22: Connection refused")
        #expect(refused.title == "Couldn’t connect to files.example.com" && refused.message.contains("refused the connection"))
        #expect(refused.symbol == "network.slash" && remote("odd").symbol == "exclamationmark.triangle")
        #expect(refused.details == "ssh: connect to host files.example.com port 22: Connection refused" && refused.action == .retry)
        #expect(remote("ssh: Could not resolve hostname files.example.com").message.contains("couldn’t be found"))
        #expect(remote("Operation timed out").message.contains("didn’t answer in time"))
        #expect(remote("connect: Network is unreachable").message.contains("can’t reach"))
        #expect(remote("Host key verification failed.").message.contains("identity"))
    }

    @Test func serviceAnswersBecomeSentences() {
        #expect(remote("Permission denied (publickey).").message.contains("didn’t accept the sign-in"))
        #expect(remote("request failed (HTTP 401)").message.contains("didn’t accept the sign-in"))
        #expect(remote("S3 error 403: AccessDenied").message.hasPrefix("You don’t have access"))
        #expect(remote("request failed (HTTP 404)").message.contains("doesn’t exist on files.example.com"))
        #expect(remote("S3 error 404: NoSuchBucket").message.contains("doesn’t exist"))
        #expect(remote("request failed (HTTP 503)").message.contains("had a problem answering"))
        let odd = remote("ssh to files.example.com failed (255).")
        #expect(odd.title == "Couldn’t open “data”" && odd.message == "Porpoise couldn’t list this folder on files.example.com.")
        #expect(odd.details == "ssh to files.example.com failed (255).")
        let worded = remote("The server is shutting down for maintenance.")
        #expect(worded.message == "The server is shutting down for maintenance." && worded.details == nil)
        let root = remote("Something happened", URL(string: "ftp://ftp.example.org")!)
        #expect(root.title == "Couldn’t open “ftp.example.org”")
    }

    @Test func onlySentencesPassAsPlainText() {
        #expect(LoadErrorPresentation.plain("The server is busy.") == "The server is busy.")
        for raw in ["FTP error 7", "(error -6600)", "failed (255).", "/var/folders/x/socket too long", "ssh: x: y", "HTTP 500 oops", " "] {
            #expect(LoadErrorPresentation.plain(raw) == nil, "\(raw)")
        }
        #expect(LoadErrorPresentation.plain(String(repeating: "a", count: 161)) == nil)
        #expect(ListState.Action.retry.title == "Try Again" && ListState.Action.goUp.title.contains("Enclosing"))
        #expect(ListState.Action.openPrivacySettings.title.hasSuffix("…"))
    }
}
