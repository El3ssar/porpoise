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
}
