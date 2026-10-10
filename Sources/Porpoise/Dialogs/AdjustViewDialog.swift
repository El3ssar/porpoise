import AppKit
import PorpoiseCore
import PorpoiseServices

enum AdjustViewDialog {
    /// Shown as a sheet on `window`; `done` runs after the new properties were applied.
    static func run(for c: ViewContainer, window: NSWindow?, done: (() -> Void)? = nil) {
        let a = NSAlert()
        a.messageText = "View Display Style"
        a.informativeText = "Properties for “\(c.url.lastPathComponent)”"
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: 190))
        let p = c.model.props
        func popup(_ items: [String], _ sel: Int, y: CGFloat, label: String) -> NSPopUpButton {
            let l = NSTextField(labelWithString: label); l.frame = CGRect(x: 0, y: y + 3, width: 110, height: 18); l.alignment = .right
            let b = NSPopUpButton(frame: CGRect(x: 118, y: y, width: 220, height: 26), pullsDown: false)
            b.addItems(withTitles: items); b.selectItem(at: sel)
            v.addSubview(l); v.addSubview(b)
            return b
        }
        let mode = popup(ViewMode.allCases.map(\.title), ViewMode.allCases.firstIndex(of: p.mode) ?? 0, y: 160, label: "View mode:")
        let roles = ItemRole.menuRoles.filter { $0 != .tags }
        let sort = popup(roles.map(\.title), roles.firstIndex(of: p.sortRole) ?? 0, y: 128, label: "Sorting:")
        let order = popup(["Ascending", "Descending"], p.sortOrder == .ascending ? 0 : 1, y: 96, label: "")
        let previews = NSButton(checkboxWithTitle: "Show previews", target: nil, action: nil); previews.state = p.previews ? .on : .off
        let hidden = NSButton(checkboxWithTitle: "Show hidden files", target: nil, action: nil); hidden.state = p.showHidden ? .on : .off
        let folders = NSButton(checkboxWithTitle: "Show folders first", target: nil, action: nil); folders.state = p.foldersFirst ? .on : .off
        previews.frame = CGRect(x: 118, y: 66, width: 220, height: 20)
        hidden.frame = CGRect(x: 118, y: 42, width: 220, height: 20)
        folders.frame = CGRect(x: 118, y: 18, width: 220, height: 20)
        [previews, hidden, folders].forEach(v.addSubview)
        a.accessoryView = v
        a.addButton(withTitle: "Apply")
        a.addButton(withTitle: "Cancel")
        a.runSheet(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }
            // Start from the current properties: they may have changed while the sheet was open.
            var np = c.model.props
            np.mode = ViewMode.allCases[safe: mode.indexOfSelectedItem] ?? np.mode
            np.sortRole = roles[safe: sort.indexOfSelectedItem] ?? np.sortRole
            np.sortOrder = order.indexOfSelectedItem == 0 ? .ascending : .descending
            np.previews = previews.state == .on
            np.showHidden = hidden.state == .on
            np.foldersFirst = folders.state == .on
            c.model.props = np
            c.model.saveProps()
            done?()
        }
    }
}
