import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Minor findings in the views, panels and dialogs (W-243, from the W-235 audit's appendices): each one pinned.
@Suite(.serialized, .isolatedSettings) @MainActor struct ViewMinorsTests {
    init() { _ = NSApplication.shared }

    /// #14: only the settings folder previews depend on rebuild them; an unrelated one leaves them alone.
    @Test func onlyPreviewSettingsResetFolderPreviews() {
        let thumbnails = Thumbnails()
        let start = thumbnails.folderGeneration
        for key in ["placesIconSize", "appLibraryIconSize", "verifyCopies", "terminalFollowDirectory"] {
            NotificationCenter.default.post(name: Settings.changed, object: key)
        }
        #expect(thumbnails.folderGeneration == start)
        NotificationCenter.default.post(name: Settings.changed, object: "pvFolders")
        #expect(thumbnails.folderGeneration == start + 1)
        NotificationCenter.default.post(name: Settings.changed, object: nil)  // several at once
        #expect(thumbnails.folderGeneration == start + 2)
    }

    /// #12: the cloud folder's second look, 0.4 s on, isn't shown over the local folder the pane went to meanwhile.
    @Test func aCloudRetryDoesNotLandOnTheNextFolder() async throws {
        let account = UUID().uuidString.lowercased()
        let root = try #require(URL(string: "gdrive://\(account)/my-drive/"))
        let backend = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = DemoCloudBackend(accounts: [
            CloudAccount(id: account, email: "fixture@example.invalid", displayName: "Fixture")
        ])
        RemoteFS.use(FailingProvider(), for: root)
        let s = try Scratch("cloud-retry")
        let locked = try s.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            RemoteFS.use(nil, for: root)
            CloudAccounts.shared.backend = backend
        }
        let pane = ViewContainer(url: root)
        try #require(await eventually { !pane.model.isLoading && pane.model.loadError != nil })
        pane.setURL(locked)
        try #require(await eventually { pane.model.location.path == locked.path && !pane.model.isLoading && pane.model.loadError != nil })
        try await Task.sleep(for: .milliseconds(700))
        #expect(!pane.messageBar.text.contains("isn’t connected"))
    }

    private final class FailingProvider: RemoteProvider {
        func list(_ folder: URL) throws -> [FileItem] { throw CocoaError(.fileReadNoPermission) }
        func rootTitle(_ url: URL) -> String { "Failing fixture" }
        func download(_ remote: URL, into localFolder: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
        func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
        func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
        func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
        func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
        func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
        func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    }
}
