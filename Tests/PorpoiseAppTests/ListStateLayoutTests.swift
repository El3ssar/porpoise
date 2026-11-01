import AppKit
import PorpoiseServices
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized) struct ListStateLayoutTests {
    @Test func narrowSearchAndFilterTitlesWrapWithoutClipping() throws {
        _ = NSApplication.shared
        for width in [160.0, 210] {
            for text in ["No items match the search", "No items match the filter"] {
                let view = ListStateView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                defer { window.close() }
                view.show(ListState(title: text, symbol: "magnifyingglass"))
                view.layoutSubtreeIfNeeded()
                let stack = try #require(view.subviews.first as? NSStackView)
                let title = try #require(stack.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
                let frame = view.convert(title.bounds, from: title)
                #expect(title.stringValue == text)
                #expect(frame.minX >= 0 && frame.maxX <= width)
                #expect(title.frame.height > title.font!.boundingRectForFont.height)
                let required = title.sizeThatFits(CGSize(width: title.frame.width, height: .greatestFiniteMagnitude))
                #expect(title.frame.height >= required.height - 1)
            }
        }
    }
    @Test func narrowErrorActionsAndDetailsStayInsideThePane() throws {
        _ = NSApplication.shared
        for width in [160.0, 210] {
            let view = ListStateView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            let state = ListState(title: "Porpoise needs Full Disk Access", details: "Permission denied", action: .openPrivacySettings, isError: true)
            view.show(state)
            view.layoutSubtreeIfNeeded()
            let stack = try #require(view.subviews.first as? NSStackView)
            let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
            #expect(buttons.count == 2)
            for button in buttons {
                let frame = view.convert(button.bounds, from: button)
                #expect(frame.minX >= 0 && frame.maxX <= width)
                #expect(button.frame.width <= width - 40)
                #expect(button.toolTip == button.title)
            }
            #expect(buttons.last?.title == state.action?.title)
        }
    }

}
