import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Opt-in WindowServer evidence from owned test windows. Never activates the application or sends global input.
@MainActor @Suite(.serialized, .isolatedSettings) struct CodeThemeCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORPOISE_CODE_THEME_CAPTURES"] != nil))
    func allSharedSurfacesInBothAppearances() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PORPOISE_CODE_THEME_CAPTURES"]), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch = try Scratch("code-theme-capture")
        let source = try scratch.file(
            "Ocean.swift",
            """
            import Foundation

            // An ocean of possibilities.
            struct Porpoise {
                let name: String = "Pacific 🐬"
                let depth: Double = 42.5
                let isCurious = true

                func explore() -> String {
                    return "Hello, \\(name)!"
                }
            }

            let ocean = Porpoise()
            ocean.explore()
            """)
        let app = NSApplication.shared, oldAppearance = app.appearance
        Settings.shared.infoShowPreview = true
        let owner = MainWindowController(urls: [scratch.url])
        let information = InformationPanel(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        let column = ColumnPreviewView(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        let parent = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        let inspectorWindow = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 420, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let columnWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        for window in [parent, inspectorWindow, columnWindow] { window.isReleasedWhenClosed = false }
        inspectorWindow.title = "Information"; inspectorWindow.contentView = information
        columnWindow.title = "Column Preview"; columnWindow.contentView = column
        let panel = SpacePreviewPanel()
        panel.hidesOnDeactivate = false
        defer {
            panel.close(); inspectorWindow.close(); columnWindow.close(); parent.close(); owner.window?.close()
            app.appearance = oldAppearance; Theme.lookChanged()
        }
        try #require(await poll { owner.view.model.rows.count == 1 })
        owner.view.list.select(source)
        information.show(hovered: nil, container: owner.view)
        column.show(source, container: owner.view)
        panel.show([try #require(FileItem.load(source))], relativeTo: parent)
        let surfaces = [
            ("space", panel, panel.code), ("information", inspectorWindow, information.codePreview),
            ("column", columnWindow, column.information.codePreview),
        ]
        for look in [AppearanceChoice.light, .dark] {
            Settings.shared.appearance = look; app.appearance = Theme.appearance
            for theme in CodeTheme.allCases {
                Settings.shared.updateAppearance { $0.codeTheme = theme }
                Theme.lookChanged()
                try #require(await poll { surfaces.allSatisfy { $0.2.document != nil && !$0.2.isLoading } })
                for (name, window, code) in surfaces {
                    window.appearance = Theme.appearance
                    window.orderFrontRegardless()
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    #expect(code.textView.string.contains("ocean.explore()") && !code.isHidden)
                    let palette = theme.palette(darkAppearance: look == .dark)
                    #expect(
                        code.layer?.backgroundColor == NSColor(rgb: palette.background.red, palette.background.green, palette.background.blue).cgColor
                    )
                    let foreground = try #require(code.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                    #expect(foreground.hexString == palette.keyword.hex)
                    let captured = try #require(WindowCapture.image(of: window.windowNumber))
                    let data = try #require(NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:]))
                    try data.write(to: folder.appendingPathComponent("\(theme.rawValue)-app-\(look.rawValue)-\(name).png"))
                    if name == "space" { #expect(panel.contentView === panel.material && panel.backgroundColor == .clear) }
                }
            }
        }
    }
}
