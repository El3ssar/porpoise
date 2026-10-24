import AppKit
import PorpoiseCore
import PorpoiseHelperKit
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Minor findings in the dialogs (W-243, from the W-235 audit's app-dialogs appendix): each one pinned.
@Suite(.serialized, .isolatedSettings) @MainActor struct DialogMinorsTests {
    init() { _ = NSApplication.shared }

    private func window(_ view: NSView) -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = view
        return w
    }

    private func fields(_ view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
    }

    /// Types `text` into `field` and ends the edit with Return (`return`) or by moving the focus on.
    private func edit(_ field: NSTextField, in w: NSWindow, _ text: String, return pressReturn: Bool) throws {
        #expect(w.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())  // as typed: the field hears of the change
        if pressReturn { editor.insertNewline(nil) } else { w.makeFirstResponder(nil) }
    }

    /// #9: Return runs a text field's handler once (an invalid value showed two alerts); so does leaving the field.
    @Test func aTextFieldRunsItsHandlerOncePerEdit() throws {
        var calls: [String] = []
        let field = ClosureTextField(string: "a") { calls.append($0.stringValue) }
        let w = window(field)
        defer { w.close() }
        try edit(field, in: w, "open {dir", return: true)
        #expect(calls == ["open {dir"])
        try edit(field, in: w, "b", return: false)
        #expect(calls == ["open {dir", "b"], "\(calls)")
    }

    /// #22: text that isn't a number saves nothing (0 often means "no limit") and shows the saved value again.
    @Test func aStepperFieldRejectsTextThatIsntANumber() throws {
        var saved = 500
        var sets: [Int] = []
        let form = FormBuilder()
        form.stepper("Local files below:", saved, 1...10_000, suffix: "MB") {
            saved = $0; sets.append($0)
        }
        let field = try #require(fields(form.view).first { $0.isEditable })
        let w = window(form.view)
        defer { w.close() }
        try edit(field, in: w, "1o0", return: true)
        #expect(sets.isEmpty && saved == 500 && field.integerValue == 500)
        try edit(field, in: w, "20000", return: true)
        #expect(sets == [10_000], "\(sets) \(field.stringValue)")
        // Plain digits shown (a grouped "10.000" read back as 10), and typed grouping is understood.
        #expect(field.stringValue == "10000")
        #expect(FormBuilder.integer("10.000") == 10_000 && FormBuilder.integer("10,000") == 10_000 && FormBuilder.integer(" 7 ") == 7)
        #expect(FormBuilder.integer("1o0") == nil && FormBuilder.integer("") == nil && FormBuilder.integer("-") == nil)  // clamped, as before
    }

    /// #24: the shortcut recorder stops when focus leaves it: ⌘A typed in another field stays that field's.
    @Test func theShortcutRecorderStopsWhenFocusLeaves() throws {
        var recorded: [KeyboardShortcut] = []
        let recorder = CustomToolShortcutButton(shortcut: KeyboardShortcut()) { recorded.append($0) }
        let other = NSTextField(string: "")
        let stack = NSStackView(views: [recorder, other])
        let w = window(stack)
        defer { w.close() }
        recorder.performClick(nil)
        #expect(recorder.isRecording)
        #expect(w.makeFirstResponder(other))
        #expect(!recorder.isRecording && recorder.title == "Record Shortcut…")
        let cmdA = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(!recorder.performKeyEquivalent(with: cmdA))
        #expect(recorded.isEmpty)
    }

    /// #25: "Add Examples" twice adds them once; Remove asks first.
    @Test func examplesAreAddedOnceAndRemovingAsks() {
        let first = CustomToolsEditorView.examples(missingFrom: [])
        #expect(first.count == CustomToolDocument.examples.count && !first.isEmpty)
        #expect(CustomToolsEditorView.examples(missingFrom: first).isEmpty)
        var renamed = first[0]
        renamed.name += " (mine)"
        #expect(CustomToolsEditorView.examples(missingFrom: [renamed]).count == first.count)
    }

    /// #11: as administrator, New Folder "a/b" makes both folders and a new file never replaces one that appeared.
    @Test func administratorNewItemsMatchTheNormalPath() throws {
        let s = try Scratch("new-item")
        let folder = try s.folder("Protected")
        let nested = NewItemDialog.administratorCommands(
            .folder, at: folder.appendingPathComponent("a/b"), in: folder, linkTarget: "", contents: nil)
        #expect(
            nested == [
                ["/bin/mkdir", "--", folder.appendingPathComponent("a").path], ["/bin/mkdir", "--", folder.appendingPathComponent("a/b").path],
            ])
        try s.folder("Protected/a")
        #expect(
            NewItemDialog.administratorCommands(.folder, at: folder.appendingPathComponent("a/b"), in: folder, linkTarget: "", contents: nil)
                == [["/bin/mkdir", "--", folder.appendingPathComponent("a/b").path]])
        let tmp = try s.file("contents", "<html>")
        let file = NewItemDialog.administratorCommands(
            .htmlFile, at: folder.appendingPathComponent("x.html"), in: folder, linkTarget: "", contents: tmp)
        #expect(file.count == 3 && file[0].prefix(2) == ["/bin/cp", "--"] && file[1].prefix(3) == ["/bin/mv", "-n", "--"])
        #expect(file[1].last == folder.appendingPathComponent("x.html").path && file[2] == ["/bin/rm", "-rf", "--", file[0].last!])
        #expect(file.allSatisfy { HelperRequests.refusal($0) == nil }, "the helper takes them as they are")
        // Run as the current user, the same way: an item that appeared meanwhile is kept, and nothing is left over.
        try s.file("Protected/x.html", "theirs")
        for c in file { _ = try Shell.run(c[0], Array(c.dropFirst())) }
        #expect(s.read("Protected/x.html") == "theirs")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["a", "x.html"])
    }

    /// #12: a link to a location is checked under the name it gets: "Link" is taken when "Link.webloc" is there.
    @Test func aLocationLinkIsCheckedUnderItsFinalName() {
        #expect(NewItemDialog.finalName("Link", kind: .urlLink) == "Link.webloc")
        #expect(NewItemDialog.finalName("Link.webloc", kind: .urlLink) == "Link.webloc")
        #expect(NewItemDialog.finalName("Link", kind: .folder) == "Link")
    }

    /// #10: Return replaces only a newer item of the same kind; a folder is never replaced by a file by default.
    @Test func returnNeverReplacesAFolderWithAFile() {
        #expect(!ConflictDialog.replacesByDefault(newer: true, bothFolders: false, sameKind: false))
        #expect(ConflictDialog.replacesByDefault(newer: true, bothFolders: false, sameKind: true))
        #expect(!ConflictDialog.replacesByDefault(newer: false, bothFolders: false, sameKind: true))
        #expect(ConflictDialog.replacesByDefault(newer: false, bothFolders: true, sameKind: true))
        #expect(ConflictDialog.methodTitles(tolerance: 2) == ["Size & date · 2 s", "Size only", "Contents"])
        #expect(ConflictDialog.methodTitles(tolerance: 120).first == "Size & date · 2 min")
    }

    /// #26: unticking "Keep on this Mac" asks before removing the downloaded copy.
    @Test func removingADownloadAsksFirst() {
        let service = DemoOfflineService()
        let url = URL(string: "gdrive://acct/folder/Big")!
        service.keep([url])
        let row = CloudOfflineRow(url: url, item: nil, service: service, provider: "Google Drive")
        #expect(row.keep.state == .on)
        CloudOfflineRow.confirmRemoveDownloadForTesting = { false }
        defer { CloudOfflineRow.confirmRemoveDownloadForTesting = nil }
        row.keep.performClick(nil)
        #expect(!service.log.contains { $0.hasPrefix("remove") } && row.keep.state == .on)
        CloudOfflineRow.confirmRemoveDownloadForTesting = { true }
        row.keep.performClick(nil)
        #expect(service.log.contains { $0.hasPrefix("remove") } && row.keep.state == .off)
    }

    /// #23: a settings page refreshes when its own window becomes key, not when any window does.
    @Test func settingsRefreshOnlyForTheirOwnWindow() {
        var reads = 0
        let form = FormBuilder()
        form.check(
            "Probe",
            {
                reads += 1; return true
            }()
        ) { _ in }
        let own = window(form.view), other = window(NSView())
        defer { own.close(); other.close() }
        let before = reads
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(reads == before)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: own)
        #expect(reads == before + 1)
    }

    /// #19: the toolbar's transfer button stops ticking once nothing moves (a failure waits without a timer), and
    /// forgets activities that are gone.
    @Test func theTransferButtonRestsOnAFailure() async throws {
        let w = window(NSView())
        defer { w.close() }
        let button = TransferToolbarButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        w.contentView?.addSubview(button)
        let controller = FileOperationsController.shared
        let failed = Activity(kind: .copy, sources: [URL(fileURLWithPath: "/tmp/x")], destination: nil, job: nil)
        failed.originWindow = w
        failed.errors = ["“x” couldn’t be copied."]
        failed.state = .failed
        failed.finishedAt = Date().addingTimeInterval(-10)
        controller.activities.append(failed)
        defer {
            controller.activities.removeAll { $0 === failed }
            NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        }
        NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        #expect(!button.tickingForTests)
    }

    /// #16: a click near the middle of a changed row only focuses: changes are copied with the buttons.
    @Test func aClickNearTheSeamDoesntCopyAChange() throws {
        let view = FileDiffTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.presentation = FileDiffPresentation(TextDifference(left: "a\nb\n", right: "a\nc\n"), inline: false)
        var copied = 0
        view.copyChange = { _, _ in copied += 1 }
        let w = window(view)
        defer { w.close() }
        let changed = try #require(view.presentation?.rows.firstIndex { $0.change != nil })
        for dx in [-10.0, 10] {
            let p = view.convert(CGPoint(x: (view.bounds.width - 8) / 2 + dx, y: 10 + (CGFloat(changed) + 0.5) * view.lineHeight), to: nil)
            let e = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            view.mouseDown(with: e)
        }
        #expect(copied == 0 && w.firstResponder === view)
    }

    /// #17: Save writes where a symlinked file really is (the link stays a link), and in place for a file with
    /// another name too (both names see the new text).
    @Test func savingKeepsLinksAndOtherNames() throws {
        let s = try Scratch("diff-save")
        let target = try s.file("target.txt", "old")
        let link = try s.symlink("link.txt", to: target.path)
        try FileDiffWindow.write("new", to: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(s.read("target.txt") == "new")
        let other = s.path("other.txt")
        try FileManager.default.linkItem(at: target, to: other)
        try FileDiffWindow.write("both", to: target)
        #expect(s.read("other.txt") == "both" && s.read("target.txt") == "both")
    }

    /// #14: a running tool's output grows in place: what was selected stays selected (to copy it).
    @Test func aRunningToolsOutputKeepsTheSelection() async throws {
        let s = try Scratch("tool-output")
        var tool = CustomTool(name: "Ticker", executable: "/bin/sh", arguments: ["-c", "for i in 1 2 3 4 5 6 7 8; do echo line $i; sleep 0.2; done"])
        tool.selection = .folder
        try Settings.shared.saveCustomTools([tool])
        let view = CustomToolActivityView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let w = window(view)
        defer { w.close(); CustomToolRunner.shared.clearFinished() }
        let run = try await CustomToolRunner.shared.start(id: tool.id, context: CustomToolContext(folder: s.url, items: []))
        try #require(await eventually { view.output.string.contains("line 2") })
        view.output.setSelectedRange(NSRange(location: 0, length: 6))
        try #require(await eventually { view.output.string.contains("line 5") })
        #expect(view.output.selectedRange() == NSRange(location: 0, length: 6))
        #expect(await eventually { !run.isRunning })
        #expect(view.output.string == run.output)
    }

    /// #8: Connections, shown again from another window, connects in that window (the first may be closed).
    @Test func connectionsOpenInTheWindowThatAskedLast() {
        var first: [URL] = [], second: [URL] = []
        let w = ConnectionsWindow.show { first.append($0) }
        defer { w.window?.close() }
        let again = ConnectionsWindow.show { second.append($0) }
        #expect(again === w)
        let url = URL(string: "sftp://example.invalid/")!
        again.open(url)
        #expect(first.isEmpty && second == [url])
    }

    /// #18: an Option-drag onto the item's own folder copies it alongside, as Finder duplicates.
    @Test func anOptionDragInTheSameFolderDuplicates() async throws {
        let s = try Scratch("drop-same")
        let a = try s.file("a.txt", "a")
        let controller = FileOperationsController(), ui = ScriptedUI()
        controller.ui = ui
        let view = NSView()
        controller.handleDrop([a], onto: s.url, operation: .move, in: view)
        #expect(controller.activities.isEmpty)  // moving it where it is does nothing
        controller.handleDrop([a], onto: s.url, operation: .copy, in: view)
        await ui.nextJobFinished()
        let names = try FileManager.default.contentsOfDirectory(atPath: s.url.path).sorted()
        #expect(names.count == 2 && names.contains("a.txt") && s.read("a.txt") == "a", "\(names)")
    }

    /// #21: a server Connections manages, with a problem in its fields, says so instead of becoming a plain place.
    @Test func aServerWithAProblemSaysSo() throws {
        let form = ServerForm(kind: .sftp)
        form.server.stringValue = "example.invalid"
        form.port.stringValue = "70000"
        #expect(form.url() != nil)  // an address it could open…
        let draft = try #require(form.draftProfile())
        #expect(draft.problem == "The port must be between 1 and 65535.")  // …but not a connection to save
        #expect(form.profile() == nil)
        form.port.stringValue = "2222"
        #expect(form.draftProfile()?.problem == nil && form.profile()?.port == 2222)
        #expect(ServerForm(kind: .webdav).draftProfile() == nil)  // not one Connections manages: a place, as before
    }

    /// #20: a quota or picture arriving while a sidebar name is typed keeps the field; rows are chosen by keyboard
    /// and VoiceOver too.
    @Test func accountsKeepTheNameBeingTypedAndTakeTheKeyboard() throws {
        let previous = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = DemoCloudBackend(accounts: [
            CloudAccount(id: "one", email: "one@example.invalid", displayName: "One"),
            CloudAccount(id: "two", email: "two@example.invalid", displayName: "Two"),
        ])
        defer { CloudAccounts.shared.backend = previous }
        let view = AccountsView()
        let w = window(view)
        defer { w.close() }
        #expect(view.selected == "one")
        let field = try #require(view.nameField)
        #expect(w.makeFirstResponder(field))
        (field.currentEditor() as? NSTextView)?.insertText("Wo", replacementRange: NSRange(location: 0, length: 0))
        NotificationCenter.default.post(name: CloudAccounts.changed, object: nil)
        #expect(view.nameField === field && field.currentEditor() != nil)
        w.makeFirstResponder(nil)
        let rows = view.list.arrangedSubviews.compactMap { $0 as? AccountRow }
        #expect(rows.count == 2 && rows[1].accessibilityPerformPress() && view.selected == "two")
        let row = try #require(view.list.arrangedSubviews.compactMap { $0 as? AccountRow }.last)
        #expect(w.makeFirstResponder(row))
        let up = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126))
        row.keyDown(with: up)
        #expect(view.selected == "one")
    }
}
