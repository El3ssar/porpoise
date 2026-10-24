import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import Testing

@testable import Porpoise

/// UI-12 / UI-5 (DESIGN-CONTRACT §6.4): every Settings page is built to one pattern, on the 4-pt grid.
@Suite(.serialized) @MainActor struct SettingsFormPatternTests {
    init() { _ = NSApplication.shared }

    private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private func scrolls(_ controller: SettingsWindowController) throws -> [(String, NSScrollView)] {
        let tabs = try #require(controller.window?.contentViewController as? NSTabViewController)
        return try tabs.tabViewItems.map { item in
            (item.label, try #require(item.viewController?.view as? NSScrollView))
        }
    }

    /// Headings sit on the 20-pt content margin; labels end on one column per page, 8 pt before their controls; check
    /// boxes and radio buttons start in that control column; a label shares its control's first baseline.
    @Test(.isolatedSettings) func everyPageFollowsTheFormPattern() throws {
        let w = SettingsWindowController()
        let window = try #require(w.window)
        defer { window.close() }
        for (page, scroll) in try scrolls(w) {
            let doc = try #require(scroll.documentView)
            // Laid out at the window's width, as when shown.
            scroll.frame = CGRect(x: 0, y: 0, width: 760, height: 580)
            doc.layoutSubtreeIfNeeded()
            let shown = Self.views(in: doc).filter { !$0.isHiddenOrHasHiddenAncestor }
            // Where the stacks put a view: its alignment rect (a label's text and a control's bezel, not their insets).
            func frame(_ v: NSView) -> CGRect { v.superview?.convert(v.alignmentRect(forFrame: v.frame), to: doc) ?? .zero }

            let headings = shown.compactMap { $0 as? NSTextField }.filter { $0.identifier == FormBuilder.headingID }
            #expect(!headings.isEmpty, "\(page) has headings")
            for h in headings {
                #expect(abs(frame(h).minX - Tokens.Space.xl) < 1, "\(page): \(h.stringValue) on the content margin")
                #expect(h.font == Tokens.font(.headline), "\(page): \(h.stringValue) in headline")
            }

            // Labelled rows: a right-aligned label, then its control.
            let rows = shown.compactMap { $0 as? NSStackView }.filter { row in
                guard let label = row.arrangedSubviews.first as? NSTextField, row.arrangedSubviews.count == 2, !label.isEditable,
                    label.alignment == .right, label.stringValue.hasSuffix(":")
                else { return false }
                return true
            }
            #expect(!rows.isEmpty || page == "Keyboard", "\(page) has labelled rows")
            let ends = Set(rows.map { (frame($0.arrangedSubviews[0]).maxX).rounded() })
            #expect(ends.count <= 1, "\(page): one label column, ends at \(ends)")
            guard let labelEnd = ends.first else { continue }
            let controlColumn = labelEnd + Tokens.Space.s
            for row in rows {
                let label = row.arrangedSubviews[0], control = row.arrangedSubviews[1]
                #expect(abs(frame(control).minX - controlColumn) < 1, "\(page): \((label as? NSTextField)?.stringValue ?? "") control column")
                #expect(row.alignment == .firstBaseline, "\(page): \((label as? NSTextField)?.stringValue ?? "") on its control's baseline")
            }
            // Check boxes and radio buttons: borderless, titled, the cell drawing the box or the circle.
            for b in shown.compactMap({ $0 as? NSButton }) where !b.isBordered && b.bezelStyle == .regularSquare && !b.title.isEmpty {
                // Check boxes and radio buttons of the form (a table's or an editor's own aren't in a form row).
                guard b.superview is NSStackView, b.enclosingScrollView === scroll else { continue }
                #expect(abs(frame(b).minX - controlColumn) < 1, "\(page): \(b.title) in the control column")
            }
        }
    }

    /// A page longer than the window fades out at the bottom while more is below, and stops fading at the end.
    @Test(.isolatedSettings) func longPagesFadeAtTheBottomUntilScrolledToTheEnd() throws {
        let w = SettingsWindowController(page: "General")
        let window = try #require(w.window)
        defer { window.close() }
        let scroll = try #require(try scrolls(w).first { $0.0 == "General" }?.1)
        window.contentView?.layoutSubtreeIfNeeded()
        let doc = try #require(scroll.documentView)
        #expect(doc.frame.height > scroll.contentView.bounds.height, "General is longer than the window")
        let fade = try #require((scroll as? FadingScrollView)?.fade)
        scroll.tile()
        #expect(!fade.isHidden)
        #expect(abs(fade.frame.height - Tokens.Space.xxl) < 1 && abs(fade.frame.width - scroll.frame.width) < 1, "\(fade.frame)")
        #expect(abs(fade.frame.minY - (scroll.isFlipped ? scroll.bounds.height - fade.frame.height : 0)) < 1, "at the bottom: \(fade.frame)")
        // Above the page and its scroller, so it covers what is cut.
        #expect(scroll.subviews.last === fade)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(fade.isHidden, "scrolled to the end")
        scroll.contentView.scroll(to: .zero)
        #expect(!fade.isHidden)
    }
}
