import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Writes what VoiceOver can read in a browser window (and a context menu's tag dots), through the same
/// NSAccessibility calls, to `$PORPOISE_AX_DUMP/ax-tree.txt`. Off unless that variable is set: it's a tool for
/// before/after comparisons (artifacts/p10/ux5), not a check.
@MainActor @Suite(.serialized, .isolatedSettings, .enabled(if: ProcessInfo.processInfo.environment["PORPOISE_AX_DUMP"] != nil))
struct AccessibilityDumpTests {
    @Test func dumpTheBrowserWindow() async throws {
        let out = try #require(ProcessInfo.processInfo.environment["PORPOISE_AX_DUMP"])
        NSApplication.shared.setActivationPolicy(.prohibited)
        let s = try Scratch()
        let deep = try s.folder("Projects/Clients/Acme/2026/Reports")
        let report = try s.file("Projects/Clients/Acme/2026/Reports/Quarterly.pdf", "pdf")
        _ = try s.file("Projects/Clients/Acme/2026/Reports/Notes.txt", "notes")
        FinderTags.set(["Red", "Blue"], on: report)
        Settings.store.set(false, forKey: "perFolder")
        AppDelegate.shared.newWindow(at: deep)
        let wc = try #require(AppDelegate.shared.windows.last)
        let w = try #require(wc.window)
        defer { w.close() }
        _ = wc.addTab(url: s.url, select: false)
        w.setContentSize(NSSize(width: 760, height: 520))
        var props = wc.view.model.props
        props.mode = .details
        props.setRoles([.size, .modificationTime], for: .details)
        wc.view.model.props = props
        wc.view.model.reload()
        #expect(await eventually { !wc.view.model.isLoading && wc.view.model.rows.count == 2 })
        w.orderFront(nil)
        w.layoutIfNeeded()
        // Tags are read in the background the first time they're drawn or asked for.
        _ = wc.view.list.accessibilityChildren()
        try await Task.sleep(nanoseconds: 500_000_000)

        var lines: [String] = []
        func describe(_ e: Any, depth: Int) {
            guard depth < 14, lines.count < 600, let o = e as? NSObject, o.responds(to: #selector(NSAccessibilityElement.accessibilityRole)) else {
                return
            }
            let role = (o.value(forKey: "accessibilityRole") as? String) ?? "-"
            var parts = [role]
            if let sub = o.value(forKey: "accessibilitySubrole") as? String { parts.append("subrole=\(sub)") }
            if let l = o.value(forKey: "accessibilityLabel") as? String, !l.isEmpty { parts.append("label=\"\(l)\"") }
            if let t = o.value(forKey: "accessibilityTitle") as? String, !t.isEmpty { parts.append("title=\"\(t)\"") }
            if let v = o.value(forKey: "accessibilityValue") { parts.append("value=\"\(v)\"") }
            if let d = o.value(forKey: "accessibilityValueDescription") as? String { parts.append("valueDescription=\"\(d)\"") }
            if o.responds(to: #selector(NSAccessibilityElement.isAccessibilitySelected)), (o.value(forKey: "accessibilitySelected") as? Bool) == true
            {
                parts.append("selected")
            }
            if o.responds(to: #selector(NSAccessibilityElement.accessibilitySortDirection)),
                let d = o.value(forKey: "accessibilitySortDirection") as? Int, d != 0
            {
                parts.append("sort=\(d == 1 ? "ascending" : "descending")")
            }
            if o.responds(to: #selector(NSAccessibilityElement.accessibilityRowCount)), let n = o.value(forKey: "accessibilityRowCount") as? Int,
                n > 0
            {
                parts.append("rows=\(n)")
            }
            var actions: [String] = []
            for (name, sel) in [
                ("press", #selector(NSAccessibilityElement.accessibilityPerformPress)),
                ("showMenu", #selector(NSAccessibilityElement.accessibilityPerformShowMenu)),
                ("setSelected", #selector(NSAccessibilityElement.setAccessibilitySelected(_:))),
            ] where overrides(o, sel) {
                actions.append(name)
            }
            if !actions.isEmpty { parts.append("actions=" + actions.joined(separator: ",")) }
            if let v = o as? NSView, v.canBecomeKeyView { parts.append("keyView") }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            for c in (o.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { describe(c, depth: depth + 1) }
        }
        /// Whether the class (not NSView/NSAccessibilityElement themselves) implements it: AppKit answers every
        /// selector, so "responds" alone says nothing.
        func overrides(_ o: NSObject, _ sel: Selector) -> Bool {
            let mine = class_getMethodImplementation(type(of: o), sel)
            let base: AnyClass = o is NSView ? NSView.self : NSAccessibilityElement.self
            return mine != class_getMethodImplementation(base, sel)
        }
        lines.append("# Browser window (Details, 2 tabs, a path too long for the field)")
        describe(w, depth: 0)
        lines.append("")
        lines.append("# Title bar toolbar (the path field and buttons; not among the window's children above)")
        func toolbar(_ v: NSView) -> NSView? { String(describing: type(of: v)) == "ToolbarView" ? v : v.subviews.lazy.compactMap(toolbar).first }
        if let frame = w.contentView?.superview, let bar = toolbar(frame) {
            func walk(_ v: NSView, depth: Int) {
                if v is BreadcrumbView || v is FlatButton { describe(v, depth: depth) } else { v.subviews.forEach { walk($0, depth: depth) } }
            }
            walk(bar, depth: 0)
        }
        lines.append("")
        lines.append("# Context menu tag dots (Red set)")
        describe(TagDotsView(current: ["Red"], action: { _ in }), depth: 0)
        try lines.joined(separator: "\n").write(toFile: out + "/ax-tree.txt", atomically: true, encoding: .utf8)
    }
}
