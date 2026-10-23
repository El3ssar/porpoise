import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct CustomToolsUITests {
    init() { _ = NSApplication.shared }
    @Test func draftValidationSaveAndCancelAreAtomic() throws {
        var saved: [CustomTool] = []
        let tool = CustomTool(name: "Original", executable: "/usr/bin/printf", arguments: ["%s", "{selection}"])
        let editor = CustomToolEditor(tool: tool) { saved.append($0) }
        editor.argumentsField.stringValue = "[\"bad{selection}\"]"
        #expect(!editor.save()); #expect(saved.isEmpty)
        editor.nameField.stringValue = "Unicode 🐬"
        editor.argumentsField.stringValue = "[\"%s\",\"{selection}\"]"
        #expect(editor.save()); #expect(saved.count == 1 && saved[0].name == "Unicode 🐬")
        #expect(saved[0].id == tool.id)
        let cancelled = CustomToolEditor(tool: tool) { saved.append($0) }
        cancelled.nameField.stringValue = "Unsaved"; cancelled.window?.close()
        #expect(saved.count == 1)
    }
    @Test func draftSurvivesUnrelatedSettingsNotifications() throws {
        let tool = CustomTool(name: "Draft", executable: "/usr/bin/true", arguments: [])
        var saved: CustomTool?
        let editor = CustomToolEditor(tool: tool) { saved = $0 }
        defer { editor.window?.close() }
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let root = try #require(editor.window?.contentView)
        let toolbar = try #require(buttons(root).first { $0.title == "Toolbar tools menu" })
        toolbar.performClick(nil)
        #expect(toolbar.state == .on)
        NotificationCenter.default.post(name: Settings.changed, object: "appearance")
        #expect(toolbar.state == .on)
        #expect(editor.save())
        #expect(saved?.placements.contains(.toolbar) == true)
    }
    @Test func settingsShowsToolsInOrderAndChecksShortcutConflicts() throws {
        var tools = CustomToolDocument.examples
        try CustomToolsEditorView.save(tools)
        let editor = CustomToolsEditorView()
        #expect(editor.numberOfRows(in: editor.table) == 3)
        #expect((editor.tableView(editor.table, viewFor: editor.table.tableColumns[0], row: 0) as? NSTextField)?.stringValue == tools[0].name)
        tools.swapAt(0, 2); try Settings.shared.saveCustomTools(tools)
        #expect((editor.tableView(editor.table, viewFor: editor.table.tableColumns[0], row: 0) as? NSTextField)?.stringValue == tools[0].name)
        tools[0].shortcut = KeyboardShortcut(key: "t", modifiers: .command); tools[1].shortcut = tools[0].shortcut
        #expect(throws: (any Error).self) { try CustomToolsEditorView.save(tools) }
        #expect(Settings.shared.customTools[0].shortcut.isEmpty)
    }
    @Test func largeSelectionAndValuePromptCancelWithoutLaunching() async throws {
        let scratch = try Scratch()
        for index in 0..<101 { try scratch.file("file-\(index).txt") }
        var tool = CustomTool(name: "Confirm", executable: "/usr/bin/printf", arguments: ["%s", "{prompt}", "{selection}"])
        tool.prompt = "Value to print"
        try Settings.shared.saveCustomTools([tool])
        let wc = MainWindowController(urls: [scratch.url]); wc.showWindow(nil)
        defer { wc.window?.close() }
        #expect(await eventually { !wc.view.model.isLoading && wc.view.model.rows.count == 101 })
        wc.view.model.selection = Set(wc.view.model.rows.map { $0.item.url })
        let before = CustomToolRunner.shared.runs.map(\.id)
        wc.executeCustomTool(tool)
        let confirmation = try #require(wc.window?.attachedSheet)
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        #expect(labels(try #require(confirmation.contentView)).contains { $0.contains("101 items") })
        wc.window?.endSheet(confirmation, returnCode: .alertSecondButtonReturn)
        #expect(await eventually { wc.window?.attachedSheet == nil })
        #expect(CustomToolRunner.shared.runs.map(\.id) == before)
        wc.view.model.selection = [scratch.path("file-0.txt")]
        wc.executeCustomTool(tool)
        let prompt = try #require(wc.window?.attachedSheet)
        #expect(labels(try #require(prompt.contentView)).contains("Value to print"))
        wc.window?.endSheet(prompt, returnCode: .alertSecondButtonReturn)
        #expect(await eventually { wc.window?.attachedSheet == nil })
        #expect(CustomToolRunner.shared.runs.map(\.id) == before)
    }
    @Test func contextMenuUsesActiveSplitSelectionAndFiltersPlacement() async throws {
        let scratch = try Scratch(); let left = try scratch.folder("Left"), right = try scratch.folder("Right")
        let file = try scratch.file("Right/日本語 'quote\"\n.txt")
        var tool = CustomTool(name: "Print", executable: "/usr/bin/printf", arguments: ["%s\n", "{selection}", "{otherFolder}"])
        tool.targets = .files; tool.selection = .one
        var hidden = tool; hidden.id = UUID(); hidden.name = "Palette only"; hidden.placements = [.commandPalette]
        try Settings.shared.saveCustomTools([tool, hidden])
        let wc = MainWindowController(urls: [left], split: [right]); defer { wc.window?.close() }
        let secondary = try #require(wc.tab.secondary)
        #expect(await eventually { !secondary.model.isLoading && secondary.model.rows.count == 1 })
        secondary.model.selection = [file]
        let menu = wc.contextMenu(for: secondary.model.rows[0].item, in: secondary)
        let tools = try #require(menu.items.first(where: { $0.title == "Custom Tools" })?.submenu)
        #expect(wc.view === secondary); #expect(wc.customToolContext.otherFolder == left)
        #expect(tools.items.map(\.title) == ["Print"]); #expect(wc.validateMenuItem(tools.items[0]))
        wc.runCustomTool(tools.items[0])
        let run = try #require(CustomToolRunner.shared.runs.first { $0.name == tool.name })
        #expect(await eventually { !run.isRunning })
        #expect(run.output == file.path + "\n" + left.path + "\n")
        let activity = CustomToolActivityView()
        #expect(activity.output.string == run.output); #expect(activity.status.stringValue == "Exit 0")
        #expect(activity.output.accessibilityLabel() == "Custom tool output")
        wc.view.model.selection = []
        #expect(!wc.validateMenuItem(tools.items[0]))
        ActivityWindowController.shared.window?.close(); CustomToolRunner.shared.clearFinished()
    }
}
