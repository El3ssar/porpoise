import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Interaction contracts exercised on unordered windows: never activates Porpoise or interrupts another app.
@MainActor @Suite(.serialized, .isolatedSettings) struct InteractionDetailsTests {
    private func key(_ code: UInt16, window: NSWindow? = nil) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
    }

    @Test func disabledToolbarMenusCannotBeOpenedByKeyboardPointerOrAccessibility() throws {
        let button = FlatButton(icon: "folder", title: "Actions")
        var requests = 0
        button.menuProvider = {
            requests += 1; return nil
        }
        button.isEnabled = false
        #expect(!button.accessibilityPerformShowMenu())
        button.keyDown(with: try key(125))
        let rightClick = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        button.rightMouseDown(with: rightClick)
        #expect(requests == 0, "A disabled control must not invoke its menu provider")
        button.isEnabled = true
        #expect(!button.accessibilityPerformShowMenu())
        #expect(requests == 1, "Enabled controls still request their menu")
    }

    @Test func rebuildingBreadcrumbCancelsAPressOnThePreviousPath() throws {
        _ = NSApplication.shared
        let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 640, height: 34))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        let recorder = BreadcrumbTargetsTests.Recorder(); view.delegate = recorder
        let parent = URL(fileURLWithPath: "/fixture/ParentA")
        view.url = parent.appendingPathComponent("Current")
        let rect = try #require(view.crumbRect(parent))
        let location = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let down = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        view.mouseDown(with: down)
        view.url = URL(fileURLWithPath: "/fixture/ParentB/Current")
        view.mouseUp(with: up)
        #expect(recorder.visits.isEmpty, "Mouse-up must not follow an unrelated folder occupying the old segment index")
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func editableLocationHasAnAccessibleName() throws {
        _ = NSApplication.shared
        let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 640, height: 34))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.beginEditing(selectAll: false)
        let field = try #require(view.subviews.compactMap { $0 as? PathField }.first)
        #expect(field.accessibilityLabel() == "Location")
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    private func conflict(folder: Bool = false, longName: Bool = false) -> ConflictDialog {
        let name = longName ? String(repeating: "Research results 日本語 ", count: 7) + ".txt" : "Research"
        let source = FileItem(url: URL(fileURLWithPath: "/fixture/source/\(name)"), name: name, isDirectory: folder, size: 0)
        let target = FileItem(url: URL(fileURLWithPath: "/fixture/destination/\(name)"), name: name, isDirectory: folder, size: 0)
        let dialog = ConflictDialog(
            info: ConflictInfo(
                source: source, destination: target, suggestedName: "Research (1)", remainingConflicts: 42,
                sourceFolder: folder ? TransferFolderSummary(itemCount: 31, bytes: 8192) : nil,
                destinationFolder: folder ? TransferFolderSummary(itemCount: 12) : nil), kind: .copy)
        dialog.window.isReleasedWhenClosed = false
        return dialog
    }

    @Test func conflictExplainsTheComparisonAndFolderContentsToAccessibility() throws {
        let dialog = conflict(folder: true)
        defer { dialog.window.close() }
        let views = try #require(dialog.window.contentView).subviews
        #expect(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "←" }, "Incoming items flow toward the destination card")
        let method = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
        #expect(method.accessibilityLabel() == "Compare files using")
        let cards = views.filter {
            $0.accessibilityLabel()?.hasPrefix("Copying:") == true || $0.accessibilityLabel()?.hasPrefix("In destination:") == true
        }
        #expect(cards.count == 2)
        let source = try #require(cards.first { $0.accessibilityLabel()?.hasPrefix("Copying:") == true })
        let target = try #require(cards.first { $0.accessibilityLabel()?.hasPrefix("In destination:") == true })
        #expect(source.accessibilityLabel()?.contains(FileFormat.itemCount(31)) == true)
        #expect(source.accessibilityLabel()?.contains(FileFormat.size(8192)) == true)
        #expect(target.accessibilityLabel()?.contains(FileFormat.itemCount(12)) == true)
        #expect(target.accessibilityLabel()?.contains(FileFormat.size(0)) == false, "Unknown folder bytes must not be announced as zero")
    }

    @Test func longConflictNamesWrapAndRemainAvailableInFull() throws {
        let dialog = conflict(longName: true)
        defer { dialog.window.close() }
        let content = try #require(dialog.window.contentView)
        let fields = content.subviews.compactMap { $0 as? NSTextField }
        let heading = try #require(fields.first { $0.stringValue.contains("already exists") })
        #expect(heading.frame.height > 18)
        #expect(heading.frame.maxY <= content.bounds.maxY - 12)
        #expect(heading.toolTip == heading.stringValue)
        let names = fields.filter { $0.stringValue == dialog.info.source.name }
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.toolTip == $0.stringValue })
        #expect(!dialog.window.isVisible && !dialog.window.isKeyWindow)
    }

    @Test func conflictCapturesRemainOffscreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["PORPOISE_INTERACTION_CAPTURES"] else { return }
        _ = NSApplication.shared
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; Theme.lookChanged() }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for look in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: look)); NSApp.appearance = appearance; Theme.lookChanged()
            for longName in [false, true] {
                let dialog = conflict(folder: !longName, longName: longName)
                defer { dialog.window.close() }
                dialog.window.appearance = appearance
                let content = try #require(dialog.window.contentView)
                content.layoutSubtreeIfNeeded()
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                appearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("conflict-\(look.rawValue)-\(longName ? "long-name" : "folders").png"))
                #expect(!dialog.window.isVisible && !dialog.window.isKeyWindow)
            }
        }
    }
}
