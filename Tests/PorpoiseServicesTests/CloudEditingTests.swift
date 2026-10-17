import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Changing Google Drive like a local disk: why a command is disabled, optimistic rows, Drive Trash with Undo.
@MainActor @Suite(.isolatedSettings) struct CloudEditingTests {
    let account = CloudAccount(id: "a1", email: "daniel@gmail.com", displayName: "Daniel")
    let folder = URL(string: "gdrive://a1/my-drive/F1/")!
    var report: URL { URL(string: "gdrive://a1/my-drive/F1/R1/")! }
    var notes: URL { URL(string: "gdrive://a1/my-drive/F1/N1/")! }

    private func model(_ accounts: [CloudAccount]? = nil) -> (CloudAccounts, DemoCloudBackend, FileOperationsController) {
        let backend = DemoCloudBackend()
        for a in accounts ?? [account] {
            _ = backend.connect(.googleDrive, openBrowser: { _ in }, done: { _ in })
            backend.finishSignIn(a)
        }
        let m = CloudAccounts()
        m.backend = backend
        let ops = FileOperationsController()
        m.operations = ops
        return (m, backend, ops)
    }

    // MARK: Reasons

    @Test func viewersAndCommentersAreToldWhy() {
        let viewer = CloudPermissions(access: .viewer, name: "Q3")
        for action in [CloudAction.addItems, .rename, .trash, .move] {
            #expect(viewer.denial(action) == "You have view-only access to “Q3”." || action == .addItems)
        }
        #expect(viewer.denial(.addItems) == "You have view-only access to “Q3”.")
        #expect(viewer.denial(.copy) == nil)
        let commenter = CloudPermissions(access: .commenter, name: "Plan")
        #expect(commenter.denial(.rename) == "You can only comment on “Plan”.")
        #expect(CloudPermissions(canCopy: false, name: "Secret").denial(.copy) == "The owner of “Secret” turned off copying and downloading.")
    }

    @Test func editorsCantTrashWhatTheyDontOwn() {
        let editor = CloudPermissions(canAddChildren: true, canRename: true, access: .editor, name: "Budget")
        #expect(editor.denial(.rename) == nil && editor.denial(.addItems) == nil)
        #expect(editor.denial(.trash) == "Only the owner can move “Budget” to the Trash.")
        #expect(editor.denial(.move) == "Only the owner can move “Budget”.")
        var shared = editor
        shared.inSharedDrive = true
        #expect(shared.denial(.trash) == "Only managers of this shared drive can move “Budget” to the Trash.")
        #expect(shared.denial(.move) == "Only managers of this shared drive can move “Budget”.")
        #expect(CloudPermissions(access: .editor).denial(.rename) == "You can’t rename this item.")
        #expect(CloudPermissions(access: .editor).denial(.addItems) == "You can’t add items to this folder.")
    }

    @Test func collectionsTakeNothing() {
        #expect(CloudPermissions(collection: .sharedWithMe).denial(.addItems)?.hasPrefix("Shared with me lists") == true)
        #expect(CloudPermissions(collection: .sharedDrives).denial(.addItems) == "Open a shared drive to add items to it.")
        #expect(CloudPermissions.owner("Mine").denial(.addItems) == nil)
        for action in CloudAction.allCases { #expect(CloudPermissions.owner().denial(action) == nil) }
    }

    @Test func theAccountComesFirst() {
        let (m, backend, _) = model()
        backend.permissionsByURL[folder] = .owner("F1")
        #expect(m.denial(.addItems, folder: folder) == nil)
        backend.setStatus("a1", .offline)
        #expect(m.denial(.addItems, folder: folder) == "You’re offline. Changes to Google Drive need a connection.")
        backend.setStatus("a1", .signInNeeded)
        #expect(m.denial(.rename, items: [report]) == "Sign in to Google Drive again to make changes.")
        backend.setStatus("a1", .ok)
        backend.setCanWrite("a1", false)
        #expect(m.denial(.trash, items: [report]) == "Allow Porpoise to make changes to Google Drive first.")
        // Copying out needs no write access.
        #expect(m.denial(.copy, items: [report]) == nil)
        // Local items are never the cloud's business; unknown accounts can't be changed.
        #expect(m.denial(.trash, items: [URL(fileURLWithPath: "/tmp/x")]) == nil)
        #expect(m.accountDenial(for: URL(string: "gdrive://zz/my-drive/")!) == "The account this folder belongs to isn’t connected.")
    }

    @Test func permissionsOfEachItemCount() {
        let (m, backend, _) = model()
        backend.permissionsByURL[report] = .owner("Report")
        backend.permissionsByURL[notes] = CloudPermissions(access: .viewer, name: "Notes")
        #expect(m.denial(.trash, items: [report]) == nil)
        #expect(m.denial(.trash, items: [report, notes]) == "You have view-only access to “Notes”.")
        #expect(m.permissions(for: report)?.canTrash == true)
    }

    @Test func trashMessagesNameTheService() {
        let (m, _, _) = model()
        #expect(m.trashMessage([report], names: [report: "Report.pdf"]) == "Moved “Report.pdf” to Google Drive Trash")
        #expect(m.trashMessage([report, notes], names: [:]) == "Moved 2 items to Google Drive Trash")
        #expect(m.providerTitle(for: URL(fileURLWithPath: "/")) == "the cloud")
    }

    // MARK: Changes and Undo

    @Test func trashGoesToTheServiceTrashAndUndoRestores() {
        let (m, backend, ops) = model()
        var trashed: [URL] = []
        m.trash([report, notes]) { t, e in
            trashed = t; #expect(e == nil)
        }
        #expect(trashed == [report, notes] && backend.trashed == [report, notes])
        #expect(ops.undoTitle == "Undo: Move to Trash")
        ops.undo(window: nil)
        #expect(backend.trashed.isEmpty)
        #expect(ops.redoTitle == "Redo: Move to Trash" && !ops.canUndo)
        ops.redo(window: nil)
        #expect(backend.trashed == [report, notes])
        #expect(ops.undoTitle == "Undo: Move to Trash")
    }

    @Test func theMessageBarsUndoTakesTheRecordOff() {
        let (m, backend, ops) = model()
        m.trash([report]) { _, _ in }
        var restored: [URL] = []
        m.untrash([report]) { r, _ in restored = r }
        #expect(restored == [report] && backend.trashed.isEmpty && !ops.canUndo)
        // A different record on top stays.
        m.trash([notes]) { _, _ in }
        ops.dropCloudUndo(CloudChange(.trashed, [report], label: "Move to Trash"))
        #expect(ops.canUndo)
    }

    @Test func renameAndNewFolderUndoThroughTheService() {
        let (m, backend, ops) = model()
        var named: FileItem?
        m.rename(report, from: "Report", to: "Final") { if case .success(let i) = $0 { named = i } }
        #expect(named?.name == "Final" && named?.url == report)
        ops.undo(window: nil)
        #expect(backend.names[report] == "Report")
        ops.redo(window: nil)
        #expect(backend.names[report] == "Final")

        var created: FileItem?
        m.createFolder(named: "Q4", in: folder) { if case .success(let i) = $0 { created = i } }
        #expect(created?.name == "Q4" && created?.isDirectory == true)
        #expect(ops.undoTitle == "Undo: New Folder")
        ops.undo(window: nil)
        #expect(backend.trashed.contains(created!.url))
        #expect(ops.redoTitle == "Redo: New Folder")
        ops.redo(window: nil)
        #expect(!backend.trashed.contains(created!.url))
    }

    @Test func refusalsLeaveNoUndoAndFailedUndosStay() {
        let (m, backend, ops) = model()
        backend.permissionsByURL[report] = CloudPermissions(access: .viewer, name: "Report")
        var error: Error?
        m.trash([report]) { _, e in error = e }
        #expect((error as? CloudEditError) == .denied("You have view-only access to “Report”."))
        #expect(backend.trashed.isEmpty && !ops.canUndo)

        backend.failNext = CloudEditError.denied("Google Drive is full.")
        var failure: Error?
        m.createFolder(named: "X", in: folder) { if case .failure(let e) = $0 { failure = e } }
        #expect(failure?.localizedDescription == "Google Drive is full." && !ops.canUndo)

        m.trash([notes]) { _, _ in }
        backend.failNext = CloudEditError.denied("offline")
        ops.undo(window: nil)
        // The record goes back for another try.
        #expect(ops.undoTitle == "Undo: Move to Trash" && backend.trashed == [notes])
    }

    @Test func writeAccessRunsTheBrowserStepOnly() {
        let (m, backend, _) = model()
        backend.setCanWrite("a1", false)
        var result: Result<Void, CloudConnectError>?
        _ = m.requestWriteAccess("a1", openBrowser: { _ in }) { result = $0 }
        #expect(backend.browserRequests.last?.absoluteString.contains("scope=drive") == true)
        backend.finishSignIn(account)
        if case .success = result {} else { Issue.record("expected success") }
        #expect(m.account("a1")?.canWrite == true)
    }

    @Test func servicesWithoutEditingSaySo() {
        final class ReadOnly: CloudBackend {
            var accounts: [CloudAccount] = [CloudAccount(id: "a1", email: "d@x.com", displayName: "D")]
            var onChange: (() -> Void)?
            func connect(_ p: CloudProvider, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void)
                -> () -> Void
            { {} }
            func signInAgain(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void)
                -> () -> Void
            { done(.success(())); return {} }
            func remove(_ id: String, done: @escaping (Error?) -> Void) {}
            func url(_ id: String, root: CloudRoot) -> URL { URL(string: "gdrive://a1/my-drive/")! }
            func accountID(for url: URL) -> String? { url.host }
            func info(for url: URL) -> CloudItemInfo? { nil }
            func resolveLink(_ text: String, done: @escaping (CloudLinkResult) -> Void) {}
            func avatar(_ id: String, done: @escaping (Data?) -> Void) {}
        }
        let m = CloudAccounts()
        m.backend = ReadOnly()
        var errors: [String] = []
        m.createFolder(named: "x", in: folder) { if case .failure(let e) = $0 { errors.append(e.localizedDescription) } }
        m.rename(report, from: "a", to: "b") { if case .failure(let e) = $0 { errors.append(e.localizedDescription) } }
        m.trash([report]) { _, e in errors.append(e?.localizedDescription ?? "") }
        m.untrash([report]) { _, e in errors.append(e?.localizedDescription ?? "") }
        #expect(errors.count == 4 && errors.allSatisfy { $0 == "This account can’t be changed from Porpoise yet." })
        #expect(m.permissions(for: report) == nil)
        var ok = false
        _ = m.requestWriteAccess("a1", openBrowser: { _ in }) { if case .success = $0 { ok = true } }
        #expect(ok)
        // Without any backend.
        let none = CloudAccounts()
        var noneError: Error?
        none.trash([report]) { _, e in noneError = e }
        #expect(noneError != nil)
        var reverted: Error?
        none.revert(CloudChange(.trashed, [report], label: "x")) { reverted = $0 }
        #expect(reverted != nil)
    }

    // MARK: Optimistic rows

    @Test func listingEditsAddRenameAndRemove() {
        let a = FileItem(url: report, name: "Report", isDirectory: false)
        let b = FileItem(url: notes, name: "Notes", isDirectory: false)
        let new = FileItem(url: URL(string: "gdrive://a1/my-drive/F1/X/")!, name: "X", isDirectory: true)
        let edit = ListingEdit(folder: folder, removed: [notes], replaced: [a.named("Final")], added: [new])
        #expect(edit.apply(to: [a, b], in: folder).map(\.name) == ["Final", "X"])
        // Additions only go into their own folder, and never twice.
        #expect(edit.apply(to: [a, b], in: URL(string: "gdrive://a1/my-drive/")!).map(\.name) == ["Final"])
        #expect(edit.apply(to: [a, new], in: folder).map(\.name) == ["Final", "X"])
        #expect(a.named(".hidden").isHidden && a.named("Final").url == a.url)
    }

    @Test func undoRecordsDescribeCloudChanges() {
        let change = CloudChange(.renamed(from: "a", to: "b"), [report], label: "Rename")
        #expect(change.inverse.kind == .renamed(from: "b", to: "a") && change.inverse.inverse == change)
        #expect(UndoRecord.cloud(change).label == "Rename")
        #expect(FileOperationsController.urls(of: .cloud(change)) == [report])
        #expect(throws: (any Error).self) { try FileActions.undo(.cloud(change)) }
    }
}

/// Optimistic rows survive listings that arrive before the service answers, keep the selection, and roll back.
@MainActor @Suite(.isolatedSettings) struct OptimisticListingTests {
    @Test func editsShowAtOnceSurviveReloadsAndRollBack() async throws {
        let s = try Scratch()
        let a = try s.file("alpha.txt"), b = try s.file("beta.txt")
        let m = try await DirectoryModel.loaded(s.url)
        m.selection = [a, b]
        let alpha = try #require(m.items.first { $0.url == a })
        let new = FileItem(url: s.url.appendingPathComponent("new folder"), name: "New Folder", isDirectory: true)
        let id = m.applyEdit(ListingEdit(folder: s.url, removed: [b], replaced: [alpha.named("Zed.txt")], added: [new]))
        #expect(m.rows.map(\.item.name) == ["New Folder", "Zed.txt"])
        #expect(m.selection == [a])
        // A listing that arrives meanwhile doesn't make the rows flicker back.
        m.reload()
        try #require(await eventually { !m.isLoading })
        #expect(m.rows.map(\.item.name) == ["New Folder", "Zed.txt"])
        // The service refused: everything as it was.
        m.endEdit(id, rollback: true)
        #expect(m.rows.map(\.item.name) == ["alpha.txt", "beta.txt"])
        m.endEdit(id)  // already ended: nothing happens
        #expect(m.rows.count == 2)
    }

    @Test func confirmedEditsStayUntilTheNextListing() async throws {
        let s = try Scratch()
        let a = try s.file("alpha.txt")
        let m = try await DirectoryModel.loaded(s.url)
        m.currentURL = a
        let id = m.applyEdit(ListingEdit(folder: s.url, removed: [a]))
        #expect(m.rows.isEmpty && m.currentURL == nil)
        m.endEdit(id)
        #expect(m.rows.isEmpty)
        m.reload()
        try #require(await eventually { !m.isLoading && m.rows.count == 1 })
        m.apply(ListingEdit(folder: s.url, added: [FileItem(url: s.url.appendingPathComponent("x"), name: "x", isDirectory: false)]))
        #expect(m.rows.map(\.item.name) == ["alpha.txt", "x"])
    }
}

@Suite struct CloudExportSkipTests {
    let unsupported = DriveError.unsupportedExport.errorDescription!
    let large = DriveError.exportTooLarge.errorDescription!

    @Test func exportSkipsAreACalmLine() {
        #expect(
            CloudExportSkip.notice(errors: ["Event signup: " + unsupported], names: ["Event signup"])
                == "“Event signup” wasn’t copied: Google can’t export it as a file. Open it in your browser instead.")
        #expect(
            CloudExportSkip.notice(errors: [large, large], names: ["A", "B"])
                == "2 Google documents weren’t copied: too large for Google to export. Open them in your browser and use File › Download.")
        #expect(
            CloudExportSkip.notice(errors: [large, unsupported], names: ["A", "B"])
                == "2 Google documents weren’t copied: Google can’t export them as files. Open them in your browser instead.")
        // Anything else keeps the errors sheet.
        #expect(CloudExportSkip.notice(errors: [unsupported, "Disk full"], names: ["A", "B"]) == nil)
        #expect(CloudExportSkip.notice(errors: [], names: []) == nil)
    }
}
