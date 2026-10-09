import AppKit
import PorpoiseCore

/// Column header of the Details view (KItemListHeader): click to sort, drag a section edge to resize,
/// drag a section to reorder, right-click to choose columns. Widths and order are remembered.
final class DetailsHeaderView: NSView {
    weak var list: ItemListView?
    var scrollX: CGFloat = 0 { didSet { needsDisplay = true } }

    private enum Drag { case none, resize(ItemRole, startX: CGFloat, startW: CGFloat), move(ItemRole, grabOffset: CGFloat, x: CGFloat) }
    private var drag: Drag = .none
    private var pressedRole: ItemRole?
    private var pressPoint: CGPoint = .zero
    private var hoverRole: ItemRole?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    private func columnRects() -> [(ItemRole, CGRect)] {
        guard let list else { return [] }
        var x = ItemListView.sidePadding - scrollX
        var out: [(ItemRole, CGRect)] = []
        for r in list.detailsRoles {
            let w = list.columnWidths[r] ?? 100
            out.append((r, CGRect(x: x, y: 0, width: w, height: bounds.height)))
            x += w
        }
        return out
    }

    /// The column whose right edge is under the point (resize handle, ±5 px).
    private func edge(at p: CGPoint) -> ItemRole? {
        columnRects().first { abs(p.x - $0.1.maxX) <= 5 }?.0
    }

    override func resetCursorRects() {
        for (_, r) in columnRects() {
            addCursorRect(CGRect(x: r.maxX - 5, y: 0, width: 10, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        Theme.viewBackground.setFill()
        bounds.fill()
        guard let list else { return }
        let props = list.model.props
        var moving: (ItemRole, CGRect)?
        for (role, r) in columnRects() {
            if case .move(let mr, _, let x) = drag, mr == role {
                moving = (role, CGRect(x: x, y: 0, width: r.width, height: r.height))
                Theme.selection.withAlphaComponent(0.12).setFill()
                r.fill()
                continue
            }
            drawSection(role, in: r, sorted: props.sortRole == role, ascending: props.sortOrder == .ascending,
                        highlighted: role == hoverRole || role == pressedRole)
        }
        if let (role, r) = moving {
            // The dragged section floats over the others, with an insertion marker where it will land.
            Theme.windowBackground.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            drawSection(role, in: r, sorted: props.sortRole == role, ascending: props.sortOrder == .ascending, highlighted: true)
            Theme.focus.setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
            if let x = insertionX() {
                Theme.selectionAlternate.setFill()
                CGRect(x: x - 1, y: 3, width: 2, height: bounds.height - 6).fill()
            }
        }
        Theme.separator.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func drawSection(_ role: ItemRole, in r: CGRect, sorted: Bool, ascending: Bool, highlighted: Bool) {
        if highlighted {
            Theme.buttonHoverBackground.setFill()
            r.fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.viewText]
        let title = role.title as NSString
        let ts = title.size(withAttributes: attrs)
        let tx = role.rightAligned ? r.maxX - ts.width - (sorted ? 26 : 8) : r.minX + 6
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r.insetBy(dx: 2, dy: 0)).addClip()
        title.draw(at: CGPoint(x: tx, y: (r.height - ts.height) / 2), withAttributes: attrs)
        if sorted, let arrow = Icons.shared.image(ascending ? "go-up" : "go-down", size: 16) {
            arrow.draw(in: CGRect(x: r.maxX - 20, y: (r.height - 12) / 2, width: 12, height: 12), from: .zero,
                       operation: .sourceOver, fraction: 0.8, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.separator.setFill()
        CGRect(x: r.maxX - 1, y: 5, width: 1, height: r.height - 10).fill()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let role = edge(at: p) == nil ? columnRects().first { $0.1.contains(p) }?.0 : nil
        if role != hoverRole { hoverRole = role; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoverRole = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressPoint = p
        if event.clickCount == 2, let role = edge(at: p), let list {
            // Double-click on an edge: fit the column to its content (Qt header behavior).
            list.setColumnWidth(list.fittingWidth(for: role), for: role)
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            return
        }
        if let role = edge(at: p), let list {
            drag = .resize(role, startX: p.x, startW: list.columnWidths[role] ?? 100)
            return
        }
        pressedRole = columnRects().first { $0.1.contains(p) }?.0
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let list else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .resize(let role, let startX, let startW):
            list.setColumnWidth(startW + p.x - startX, for: role)
            needsDisplay = true
        case .move(let role, let grab, _):
            drag = .move(role, grabOffset: grab, x: p.x - grab)
            needsDisplay = true
        case .none:
            // Start moving a section once the mouse travels a bit (Name stays first: it hosts icons and the tree).
            guard let role = pressedRole, role != .name, abs(p.x - pressPoint.x) > 4,
                  let r = columnRects().first(where: { $0.0 == role })?.1 else { return }
            drag = .move(role, grabOffset: pressPoint.x - r.minX, x: p.x - (pressPoint.x - r.minX))
            NSCursor.closedHand.set()
            needsDisplay = true
        }
    }

    /// Where the moving section would be inserted (x of the gap), nil if outside.
    private func insertionX() -> CGFloat? {
        guard case .move(_, _, let x) = drag else { return nil }
        let rects = columnRects()
        guard let target = targetIndex() else { return nil }
        return target < rects.count ? rects[target].1.minX : (rects.last?.1.maxX ?? x)
    }

    private func targetIndex() -> Int? {
        guard case .move(let role, _, let x) = drag, let list else { return nil }
        let rects = columnRects()
        let w = list.columnWidths[role] ?? 100
        let center = x + w / 2
        var idx = rects.count
        for (i, (_, r)) in rects.enumerated() where center < r.midX { idx = i; break }
        return max(1, idx)   // never before Name
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none; pressedRole = nil; needsDisplay = true; NSCursor.arrow.set(); window?.invalidateCursorRects(for: self) }
        guard let list else { return }
        switch drag {
        case .resize: return
        case .move(let role, _, _):
            guard var target = targetIndex() else { return }
            var roles = list.detailsRoles
            guard let from = roles.firstIndex(of: role) else { return }
            roles.remove(at: from)
            if target > from { target -= 1 }
            roles.insert(role, at: min(target, roles.count))
            var props = list.model.props
            props.setRoles(Array(roles.dropFirst()), for: .details)
            list.model.props = props
            list.model.saveProps()
            return
        case .none:
            break
        }
        let p = convert(event.locationInWindow, from: nil)
        if let role = pressedRole, columnRects().first(where: { $0.1.contains(p) })?.0 == role {
            var props = list.model.props
            if props.sortRole == role {
                props.sortOrder = props.sortOrder == .ascending ? .descending : .ascending
            } else {
                props.sortRole = role
                props.sortOrder = .ascending
            }
            list.model.props = props
            list.model.saveProps()
        }
    }

    // MARK: Context menu (Dolphin's header menu)

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let list else { return nil }
        let m = NSMenu()
        let current = Set(list.model.props.roles(for: .details))
        func roleItem(_ role: ItemRole) -> NSMenuItem {
            let it = NSMenuItem(title: role.title, action: #selector(toggleRole(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = role.rawValue
            it.state = current.contains(role) ? .on : .off
            return it
        }
        for role in ItemRole.menuRoles where role != .name { m.addItem(roleItem(role)) }
        let other = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for role in ItemRole.otherRoles { sub.addItem(roleItem(role)) }
        other.submenu = sub
        m.addItem(other)
        m.addItem(.separator())
        let auto = NSMenuItem(title: "Automatic Column Widths", action: #selector(autoWidths), keyEquivalent: "")
        auto.target = self
        auto.state = ItemListView.savedColumnWidths.isEmpty ? .on : .off
        m.addItem(auto)
        return m
    }

    @objc private func toggleRole(_ sender: NSMenuItem) {
        guard let list, let raw = sender.representedObject as? String, let role = ItemRole(rawValue: raw) else { return }
        var props = list.model.props
        var roles = props.roles(for: .details)
        if let i = roles.firstIndex(of: role) { roles.remove(at: i) } else { roles.append(role) }
        props.setRoles(roles, for: .details)
        list.model.props = props
        list.model.saveProps()
    }

    @objc private func autoWidths() {
        list?.resetColumnWidths()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}
