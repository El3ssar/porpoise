import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Quartz
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct CodePreviewTests {
    @Test func sharedViewHighlightsAndCancelsStaleLoads() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let first = try scratch.file("first.swift", String(repeating: "let first = 1\n", count: 10000))
        let second = try scratch.file("second.py", "def café():\n    return 42\n")
        let view = CodePreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        view.load(first)
        view.load(second)
        try #require(await poll { !view.isLoading })
        #expect(view.document?.language == .python && view.textView.string.contains("café"))
        #expect(!view.textView.string.contains("first"))
        #expect(view.textView.isSelectable && !view.textView.isEditable)
        #expect(!view.textView.drawsBackground && !view.scrollView.drawsBackground && !view.scrollView.contentView.drawsBackground)
        let color = view.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        var expected: NSColor?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { expected = CodePreviewView.syntaxColor(.keyword).usingColorSpace(.sRGB) }
        #expect(color == expected)
        Theme.lookChanged()
        #expect(view.document?.language == .python && view.textView.string.contains("café"))
        view.cancel()
        #expect(view.document == nil && view.textView.string.isEmpty)
    }

    @Test func extensionlessScriptsAreSniffedAndImagesKeepNativePreviews() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let script = try scratch.file("script", "#!/usr/bin/env python3\nprint(42)\n")
        let image = try scratch.file("image.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
        #expect(CodePreviewView.supports(try #require(FileItem.load(script))))
        #expect(!CodePreviewView.supports(try #require(FileItem.load(image))))
        let view = CodePreviewView(frame: .zero)
        view.load(script)
        try #require(await poll { !view.isLoading })
        #expect(view.document?.language == .python)
    }

    @Test func syntaxColorsFollowCustomPaletteWithReadableContrast() {
        _ = NSApplication.shared
        let app = NSApplication.shared, previous = NSApplication.shared.appearance
        defer { app.appearance = previous }
        app.appearance = NSAppearance(named: .aqua)
        var theme = AppearanceTheme.system(dark: false)
        theme.name = "Preview test palette"
        theme[.windowBackground] = ThemeColor(255, 255, 255)
        theme[.viewBackground] = ThemeColor(255, 255, 255)
        theme.terminalPalette[5] = ThemeColor(130, 0, 20)
        var preferences = Settings.shared.appearancePreferences
        preferences.customTheme = theme; preferences.themeName = "Custom"
        Settings.shared.appearancePreferences = preferences
        let red = CodePreviewView.syntaxColor(.keyword)
        theme.terminalPalette[5] = ThemeColor(0, 45, 145)
        preferences.customTheme = theme
        Settings.shared.appearancePreferences = preferences
        let blue = CodePreviewView.syntaxColor(.keyword)
        #expect(red != blue)
        for kind: SyntaxToken.Kind in [.keyword, .type, .string, .comment, .number, .key, .tag, .heading, .attribute] {
            #expect(Tokens.contrast(CodePreviewView.syntaxColor(kind), Theme.viewBackground) >= 4.5)
        }
    }

    @Test func renderedTextContrastsWithBothBackdropExtremes() async throws {
        let app = NSApplication.shared, previous = NSApplication.shared.appearance
        defer { app.appearance = previous; Theme.lookChanged() }
        let scratch = try Scratch()
        let file = try scratch.file("contrast.swift", "let name: String = \"value\" // comment\nlet count = 42\n")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: appearance)
            let view = CodePreviewView(frame: .zero)
            let initial = try #require(view.layer?.backgroundColor)
            view.load(file)
            try #require(await poll { !view.isLoading })
            #expect(view.layer?.backgroundColor == initial)
            let backdrop = try #require(NSColor(cgColor: initial))
            #expect(backdrop.alphaComponent > 0 && backdrop.alphaComponent < 1)
            let storage = try #require(view.textView.textStorage)
            let document = try #require(view.document)
            let offsets = document.tokens.spans.map(\.range.location) + [4]
            for underlay in [NSColor.black, .white] {
                let composite = try #require(underlay.blended(withFraction: backdrop.alphaComponent, of: backdrop.withAlphaComponent(1)))
                for offset in offsets {
                    let foreground = try #require(storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor)
                    #expect(Tokens.contrast(foreground, composite) >= 4.5)
                }
            }
        }
    }

    @Test func boundedViewExplainsTruncationAndRejectsBinary() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let big = try scratch.file("big.swift", String(repeating: "let x = 1\n", count: 10000))
        let binary = try scratch.file("binary.swift", "a\0b")
        let view = CodePreviewView(frame: .zero)
        view.load(big)
        try #require(await poll { !view.isLoading })
        #expect(view.document?.displayedLines == 2000 && view.document?.truncated == true)
        #expect(view.note.stringValue.contains("2000"))
        view.load(binary)
        try #require(await poll { !view.isLoading })
        #expect(view.document == nil && view.note.stringValue == "Text preview unavailable")
    }

    @Test func glassRootSurvivesContentThemeErrorAndReopen() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let source = try scratch.file("sample.swift", "let dolphin = 42\n")
        let plain = try scratch.file("sample.pdf", "%PDF-1.7")
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let panel = SpacePreviewPanel()
        defer { panel.close(); parent.close() }
        let material = panel.material
        panel.show([try #require(FileItem.load(source))], relativeTo: parent)
        #expect(panel.hidesOnDeactivate)
        #expect(panel.contentView === material && !panel.isOpaque && panel.backgroundColor == .clear)
        try #require(await poll { panel.state == "code" })
        for look in [AppearanceChoice.light, .dark] {
            Settings.shared.appearance = look
            Theme.lookChanged()
            Theme.dress(panel)
            #expect(panel.contentView === material && panel.backgroundColor == .clear)
        }
        panel.show([try #require(FileItem.load(plain))], relativeTo: parent)
        #expect(panel.state == "quicklook" && panel.contentView === material)
        #expect(panel.backgroundColor == .clear)
        panel.close()
        #expect(panel.state == "empty")
        panel.show([try #require(FileItem.load(source))], relativeTo: parent)
        try #require(await poll { panel.state == "code" })
        #expect(panel.contentView === material && panel.backgroundColor == .clear)
    }

    @Test func navigationIndexAndCloseKeysUseOnlyLocalEvents() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let a = try scratch.file("a.swift", "let a = 1"), b = try scratch.file("b.swift", "let b = 2")
        let parent = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let panel = SpacePreviewPanel()
        defer { panel.close(); parent.close() }
        panel.show([try #require(FileItem.load(a)), try #require(FileItem.load(b))], relativeTo: parent)
        panel.move(1)
        #expect(panel.itemIndex == 1)
        panel.move(50)
        #expect(panel.itemIndex == 1)
        panel.move(-1)
        #expect(panel.itemIndex == 0)
        var keys: [UInt16] = []
        panel.onArrow = { keys.append($0.keyCode) }
        for key: UInt16 in [123, 124, 125, 126] {
            panel.sendEvent(
                try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                        keyCode: key)))
        }
        #expect(keys == [123, 124, 125, 126])
        for key: UInt16 in [49, 53] {
            panel.show([try #require(FileItem.load(a))], relativeTo: parent)
            panel.sendEvent(
                try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                        keyCode: key)))
            #expect(!panel.isVisible && panel.state == "empty")
        }
    }

    @Test func invalidInspectorTextFallsBackToTheIcon() async throws {
        _ = NSApplication.shared
        Settings.shared.infoShowPreview = true
        Settings.shared.previewText = false
        let scratch = try Scratch()
        let binary = try scratch.file("binary.plist", "bplist00\0binary")
        let wc = MainWindowController(urls: [binary.deletingLastPathComponent()])
        defer { wc.window?.close() }
        try #require(await poll { wc.view.model.rows.count == 1 })
        wc.view.list.select(binary)
        let panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        panel.show(hovered: nil, container: wc.view)
        try #require(await poll { panel.codePreview.isHidden })
        #expect(panel.codePreview.document == nil)
        #expect(panel.subviews.contains { ($0 as? NSImageView)?.image != nil && !$0.isHidden })
        let column = ColumnPreviewView(frame: .zero)
        column.show(binary, container: wc.view)
        try #require(await poll { column.information.codePreview.isHidden })
        #expect(column.information.subviews.contains { ($0 as? NSImageView)?.image != nil && !$0.isHidden })
    }

    @Test func informationUsesCodeEvenWhenTextThumbnailsAreOff() async throws {
        _ = NSApplication.shared
        Settings.shared.previewText = false
        Settings.shared.infoShowPreview = true
        let scratch = try Scratch()
        let file = try scratch.file("inspector.swift", "let inspected = 42")
        let wc = MainWindowController(urls: [file.deletingLastPathComponent()])
        defer { wc.window?.close() }
        try #require(await poll { wc.view.model.rows.count == 1 })
        wc.view.list.select(file)
        let panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        panel.show(hovered: nil, container: wc.view)
        try #require(await poll { panel.codePreview.document != nil })
        #expect(!panel.codePreview.isHidden && panel.codePreview.document?.language == .swift)
        let column = ColumnPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        column.show(file, container: wc.view)
        try #require(await poll { column.information.codePreview.document != nil && !column.information.codePreview.isLoading })
        #expect(column.information.codePreview.document?.language == .swift)
        Settings.shared.infoShowPreview = false
        panel.refresh()
        #expect(panel.codePreview.isHidden)
    }
}
