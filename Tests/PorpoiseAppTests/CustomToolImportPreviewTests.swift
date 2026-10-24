import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct CustomToolImportPreviewTests {
    @Test func previewShowsExecutableAndQuotedArgumentsBeforeAnySettingsChange() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let names = ["a b.txt", "quote'\".txt", "line\nbreak 日本語.txt", "$(touch INJECTED).txt", "{{folder}}.txt"]
        for name in names { try scratch.file(name, "Fixture\n") }
        let tool = CustomTool(name: "Print Literal Paths", executable: "/usr/bin/printf", arguments: ["<%s>\n", "{selection}"])
        let document = CustomToolDocument(tools: [tool] + CustomToolDocument.examples)
        let before = Settings.shared.customTools
        let alert = CustomToolsEditorView.importConfirmation(for: document)
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let preview = try #require(scroll.documentView as? NSTextView)
        #expect(preview.string.contains(tool.executable))
        #expect(preview.string.contains(String(reflecting: tool.arguments[0])))
        #expect(document.tools.allSatisfy { preview.string.contains($0.name) && preview.string.contains($0.executable) })
        #expect(!preview.isEditable && preview.isSelectable && preview.accessibilityLabel() == "Commands to import")
        #expect(Settings.shared.customTools == before)
        #expect(alert.buttons.map(\.title) == ["Import", "Cancel"])
        guard let folder = ProcessInfo.processInfo.environment["PORPOISE_TOOLS_CAPTURE_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Optional review artifacts render real production views without depending on Stage Manager's thumbnails.
        // These establish layout/content, not active-window desktop blending or spoken VoiceOver acceptance.
        func capture(_ window: NSWindow, name: String) throws {
            for (look, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try #require(NSAppearance(named: appearanceName))
                Settings.shared.appearance = look == "light" ? .light : .dark
                window.appearance = appearance
                let view = try #require(window.contentView?.superview)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + "-" + look + ".png"))
            }
        }
        alert.layout()
        defer { alert.window.close() }
        try capture(alert.window, name: "import")
        try Settings.shared.saveCustomTools(document.tools)
        let settings = SettingsWindowController(page: "Custom Tools")
        defer { settings.window?.close() }
        try capture(try #require(settings.window), name: "settings")
        let editor = CustomToolEditor(tool: tool) { _ in Issue.record("Capture fixture must not save the draft.") }
        defer { editor.window?.close() }
        try capture(try #require(editor.window), name: "editor")
        let context = CustomToolContext(folder: scratch.url, items: names.map { FileItem(url: scratch.path($0), name: $0, isDirectory: false) })
        let run = try await CustomToolRunner.shared.start(id: tool.id, context: context)
        #expect(await eventually { !run.isRunning })
        #expect(run.exitStatus == 0 && run.output == names.map { "<" + scratch.path($0).path + ">\n" }.joined())
        #expect(!FileManager.default.fileExists(atPath: scratch.path("INJECTED").path))
        ActivityWindowController.shared.showTools()
        defer { ActivityWindowController.shared.window?.close(); CustomToolRunner.shared.clearFinished() }
        try capture(try #require(ActivityWindowController.shared.window), name: "activity")
    }
}
