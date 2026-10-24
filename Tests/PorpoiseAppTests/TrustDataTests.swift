import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct TrustDataTests {
    init() { _ = NSApplication.shared }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func trashAndDeleteKeepTheirExplicitMeaningWithAShiftSender() async throws {
        let scratch = try Scratch(), file = try scratch.file("safe.txt", "keep")
        let owner = MainWindowController(urls: [scratch.url])
        defer { owner.window?.close() }
        try #require(await eventually { !owner.view.model.isLoading })
        owner.view.model.selection = [file]
        let controller = makeController(ScriptedUI())
        controller.prepareJob = { $0.cancel() }
        owner.fileOperations = controller
        let shift = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil, characters: "\u{f728}",
                charactersIgnoringModifiers: "\u{f728}", isARepeat: false, keyCode: 117))
        owner.moveToTrash(shift)
        #expect(controller.activities.last?.kind == .trash)
        owner.deleteItem(shift)
        #expect(controller.activities.last?.kind == .delete)
        try #require(await eventually { controller.activities.allSatisfy { $0.state.isEnded } })
        #expect(scratch.read("safe.txt") == "keep")
    }

    @Test(arguments: ["run.sh", "run.command"]) func everyFileOpenEntryPointChecksExecutablePolicy(_ name: String) async throws {
        let scratch = try Scratch(), file = try scratch.file(name, "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let item = try #require(FileItem.load(file))
        let owner = MainWindowController(urls: [scratch.url])
        defer { owner.window?.close() }
        var asked = 0, ran = 0, opened = 0, applicationLookups = 0
        owner.localFileOpening.ask = { _, _, done in
            asked += 1; done(.alertThirdButtonReturn)
        }
        owner.localFileOpening.run = { _ in ran += 1 }
        owner.localFileOpening.open = { _ in opened += 1 }
        owner.localFileOpening.applications = { _ in
            applicationLookups += 1; return []
        }
        Settings.shared.executableAction = .ask
        owner.breadcrumb(owner.tab.navigators[0], navigateTo: file, newTab: false)
        try #require(await eventually { asked == 1 })
        owner.container(owner.view, middleClicked: item)
        #expect(asked == 2)
        owner.openFiles([item])
        try #require(await eventually { asked == 3 })
        #expect(ran == 0 && opened == 0 && applicationLookups == 0)
        Settings.shared.executableAction = .run
        owner.container(owner.view, middleClicked: item)
        #expect(ran == 1 && opened == 0)
        Settings.shared.executableAction = .open
        owner.container(owner.view, middleClicked: item)
        #expect(ran == 1 && opened == 1 && applicationLookups == 0)
    }

    @Test func unknownDatesNeverMakeReplaceTheReturnDefault() throws {
        for sourceDate: Date? in [nil, Date(timeIntervalSince1970: 100)] {
            for targetDate: Date? in [nil, Date(timeIntervalSince1970: 200)] where sourceDate == nil || targetDate == nil {
                let source = FileItem(
                    url: URL(fileURLWithPath: "/fixture/src/a"), name: "a", isDirectory: false, size: 3, modificationDate: sourceDate)
                let target = FileItem(
                    url: URL(fileURLWithPath: "/fixture/dst/a"), name: "a", isDirectory: false, size: 3, modificationDate: targetDate)
                let dialog = ConflictDialog(info: ConflictInfo(source: source, destination: target, suggestedName: "a (1)"), kind: .copy)
                dialog.window.isReleasedWhenClosed = false
                defer { dialog.window.close() }
                let views = descendants(try #require(dialog.window.contentView))
                let defaults = views.compactMap { $0 as? NSButton }.filter { $0.keyEquivalent == "\r" }
                #expect(defaults.map(\.title) == ["Skip"])
                #expect(views.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("date is unavailable") })
            }
        }
    }

    @Test func propertiesEscapeAndCloseNeverRenameAndReturnUsesSharedConfirmations() async throws {
        Settings.shared.confirmRenameType = true; Settings.shared.confirmRenameHide = true
        let scratch = try Scratch(), file = try scratch.file("original.txt", "bytes")
        let item = try #require(FileItem.load(file))
        func controller() async throws -> (PropertiesWindow, NSTextField) {
            let properties = PropertiesWindow(urls: [file], items: [item])
            try #require(await eventually { !properties.localItems.isEmpty })
            let content = try #require(properties.window?.contentView)
            let field = try #require(
                descendants(content).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue == "original.txt" })
            return (properties, field)
        }
        let (cancelled, draft) = try await controller()
        draft.stringValue = "changed.txt"
        #expect(cancelled.control(draft, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(draft.stringValue == "original.txt")
        draft.stringValue = "closing.txt"; cancelled.window?.close()
        #expect(scratch.listing("") == ["original.txt"])
        let (applied, field) = try await controller()
        defer { applied.window?.close() }
        var questions: [String] = []
        applied.itemRenaming.confirm = { alert, _, done in
            questions.append(alert.messageText); done(false)
        }
        field.stringValue = ".hidden.sh"
        #expect(applied.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(questions == ["Change File Type"] && scratch.listing("") == ["original.txt"])
        applied.itemRenaming.confirm = { alert, _, done in
            questions.append(alert.messageText); done(true)
        }
        #expect(applied.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try #require(await eventually { FileManager.default.fileExists(atPath: scratch.path(".hidden.sh").path) })
        #expect(questions == ["Change File Type", "Change File Type", "Hide this File?"])
        #expect(scratch.read(".hidden.sh") == "bytes")
    }

    @Test func sharedRenameRetriesPermissionFailureThroughTheSameAuthorizationPath() async throws {
        let scratch = try Scratch(), file = try scratch.file("original.txt", "safe")
        let item = try #require(FileItem.load(file))
        var renamer = ItemRenaming(), attempts: [(URL, URL)] = [], completed = false
        renamer.operation = { _, _ in throw POSIXError(.EACCES) }
        renamer.authorize = { old, new, _ in
            attempts.append((old, new)); return false
        }
        renamer.rename(item, to: "new.txt", showingHidden: false, window: nil) { result in
            #expect(result == nil); completed = true
        }
        try #require(await eventually { completed })
        #expect(attempts.count == 1 && attempts[0].0 == file && attempts[0].1 == scratch.path("new.txt"))
        #expect(scratch.read("original.txt") == "safe")
    }

    @Test func errorSheetNamesEachFailureAndNeverInventsASourceForAnUnpairedError() throws {
        let a = URL(fileURLWithPath: "/fixture/folder/a.txt"), b = URL(fileURLWithPath: "/fixture/folder/b.txt")
        let c = URL(fileURLWithPath: "/fixture/other/c.txt")
        let activity = Activity(kind: .copy, sources: [a.deletingLastPathComponent(), c], destination: nil, job: nil)
        activity.failedSources = activity.sources
        activity.errors = ["first error", "second error", "third error", "unknown error"]
        activity.failures = zip([a, b, c, nil], activity.errors).map { TransferFailure(source: $0.0, message: $0.1) }
        let owner = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { if let sheet = owner.attachedSheet { owner.endSheet(sheet); sheet.close() }; owner.close() }
        let dialogs = FileOperationsDialogs()
        dialogs.showTransferErrors(activity, window: owner)
        let sheet = try #require(owner.attachedSheet), content = try #require(sheet.contentView)
        let views = descendants(content), fields = views.compactMap { $0 as? NSTextField }
        #expect(
            fields.filter { [a.absoluteString, b.absoluteString, c.absoluteString].contains($0.toolTip ?? "") }.map(\.stringValue) == [
                "a.txt", "b.txt", "c.txt",
            ])
        #expect(fields.contains { $0.stringValue == "Item 4" && $0.toolTip == nil })
        #expect(views.compactMap { $0 as? NSButton }.filter { $0.title == "Reveal" }.count == 3)
    }
}
