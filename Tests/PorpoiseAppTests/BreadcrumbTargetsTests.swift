import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Pointer, layout and visual contracts without ordering or activating a window.
@MainActor @Suite(.serialized, .isolatedSettings) struct BreadcrumbTargetsTests {
    final class Canvas: NSView {
        override func draw(_ dirtyRect: NSRect) {
            Theme.windowBackground.setFill(); bounds.fill()
        }
    }

    final class Recorder: BreadcrumbDelegate {
        var visits: [(URL, Bool)] = []
        func breadcrumb(_ b: BreadcrumbView, navigateTo url: URL, newTab: Bool) { visits.append((url, newTab)) }
        func breadcrumbActivated(_ b: BreadcrumbView) {}
        func breadcrumb(_ b: BreadcrumbView, drop urls: [URL], onto folder: URL, operation: NSDragOperation) {}
    }

    @Test func parentPaddingAndTopEdgeNavigateWithoutEditing() throws {
        _ = NSApplication.shared
        let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 640, height: 34))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        let parent = URL(fileURLWithPath: "/Library/Fonts")
        view.url = parent.appendingPathComponent("Collection")
        let recorder = Recorder(); view.delegate = recorder
        let rect = try #require(view.crumbRect(parent))
        let point = CGPoint(x: rect.minX + 1, y: 3)
        try #require(rect.contains(point), "The space above the text belongs to the folder, not the path editor")
        #expect(rect.height == 30)
        for flags: NSEvent.ModifierFlags in [[], .command] {
            let location = view.convert(point, to: nil)
            let down = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: location, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseUp, location: location, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            view.mouseDown(with: down); view.mouseUp(with: up)
        }
        #expect(recorder.visits.map(\.0) == [parent, parent])
        #expect(recorder.visits.map(\.1) == [false, true])
        #expect(!view.isEditing && !window.isVisible && !window.isKeyWindow)
    }

    @Test func keyboardCanReachPlacesAndLocationMenusWithoutShowingAWindow() throws {
        _ = NSApplication.shared
        let saved = KeyboardAccess.isFull; defer { KeyboardAccess.isFull = saved }
        KeyboardAccess.isFull = { true }
        let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 640, height: 34))
        view.url = URL(fileURLWithPath: "/Library/Fonts")
        view.showPlacesButton = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(view))
        for _ in 0..<20 {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
            view.keyDown(with: event)
        }
        #expect(view.focusRingMaskBounds.minX == 4, "Left Arrow reaches the Places button, before the folder crumbs")
        let right = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        view.keyDown(with: right)
        #expect(view.focusRingMaskBounds.minX == 30, "The location-root menu follows Places")
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func commandReturnAndAccessibleFoldersKeepTheirNavigationTargets() throws {
        _ = NSApplication.shared
        let saved = KeyboardAccess.isFull; defer { KeyboardAccess.isFull = saved }
        KeyboardAccess.isFull = { true }
        let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 640, height: 34))
        let parent = URL(fileURLWithPath: "/fixture/Parent")
        view.url = parent.appendingPathComponent("Current"); view.showPlacesButton = true
        let recorder = Recorder(); view.delegate = recorder
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded(); #expect(window.makeFirstResponder(view))
        for (code, flags): (UInt16, NSEvent.ModifierFlags) in [(123, []), (36, .command)] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
            )
            view.keyDown(with: event)
        }
        #expect(recorder.visits.map { $0.0.path } == [parent.path] && recorder.visits.map(\.1) == [true])
        for width: CGFloat in [640, 120] {
            view.frame.size.width = width; view.layout()
            let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
            #expect(children.contains { $0.accessibilityLabel() == "Show Places" && $0.accessibilityRole() == .popUpButton })
            #expect(children.contains { $0.accessibilityLabel() == "Show Locations on This Path" && $0.accessibilityRole() == .popUpButton })
            let parentElement = try #require(children.first { $0.accessibilityLabel() == "Parent" })
            #expect(parentElement.accessibilityPerformPress())
            #expect(recorder.visits.last?.0.path == parent.path && recorder.visits.last?.1 == false)
        }
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func narrowPathKeepsParentAndOverflowWithinBounds() throws {
        let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 180, height: 34))
        let parent = URL(fileURLWithPath: "/Library/A")
        view.url = parent.appendingPathComponent("B")
        let parentRect = try #require(view.crumbRect(parent))
        let current = try #require(view.crumbRect(view.url))
        #expect(parentRect.width >= 36 && current.width >= 36)
        #expect(parentRect.minX >= 36, "A generous overflow target remains before the parent")
        #expect(parentRect.maxX <= current.minX && current.maxX <= view.bounds.maxX - 4)
        view.frame.size.height = 42
        view.layout()
        #expect(view.crumbRect(parent)?.height == 38, "Hit targets follow height as well as width")
    }

    @Test func parentTakesPriorityOverRootPrefixAtTheWidthThreshold() throws {
        let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 200, height: 34))
        let parent = URL(fileURLWithPath: "/Library/A")
        view.url = parent.appendingPathComponent("Current0000")
        #expect(view.crumbRect(parent) != nil)
        #expect(try #require(view.crumbRect(view.url)).maxX <= view.bounds.maxX)
    }

    @Test func longNamesRemainInsideEvenVeryNarrowPaths() throws {
        for width: CGFloat in [40, 80, 120, 180, 260, 640] {
            let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: width, height: 34))
            view.url = URL(fileURLWithPath: "/Library/A very long parent folder/An even longer current folder with Unicode 日本語")
            let current = try #require(view.crumbRect(view.url))
            if width >= 180 { #expect(view.crumbRect(view.url.deletingLastPathComponent()) != nil, "Elide names before hiding the parent") }
            #expect(current.minX >= 0 && current.maxX <= width)
            #expect(current.width > 0)
            #expect((view.accessibilityChildren() ?? []).count >= 3)
        }
    }

    @Test func lightAndDarkCapturesStayOffscreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["PORPOISE_BREADCRUMB_CAPTURES"] else { return }
        _ = NSApplication.shared
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; Theme.lookChanged() }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for look in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: look)); NSApp.appearance = appearance; Theme.lookChanged()
            for width: CGFloat in [180, 640] {
                let view = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: width, height: 34))
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                let canvas = Canvas(frame: view.frame)
                canvas.addSubview(view)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = canvas
                defer { window.close() }
                view.url = URL(fileURLWithPath: "/Library/Documents/Research/Project")
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                appearance.performAsCurrentDrawingAppearance { canvas.cacheDisplay(in: canvas.bounds, to: bitmap) }
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("breadcrumb-\(look.rawValue)-\(Int(width)).png"))
                #expect(!window.isVisible && !window.isKeyWindow)
            }
        }
    }
}
