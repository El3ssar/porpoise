import AppKit
import PorpoiseServices

/// VoiceOver for the custom-drawn Places panel: an outline of section headings (press folds or unfolds them) and
/// places (press opens them; the one shown in the view reads as selected).
extension PlacesPanel {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .outline }
    override func accessibilityLabel() -> String? { "Places" }
    override func accessibilityChildren() -> [Any]? { rows.indices.map { PlaceAccessibilityElement(panel: self, index: $0) } }
}

final class PlaceAccessibilityElement: NSAccessibilityElement {
    private weak var panel: PlacesPanel?
    private let index: Int

    init(panel: PlacesPanel, index: Int) {
        self.panel = panel
        self.index = index
        super.init()
        setAccessibilityParent(panel)
        setAccessibilityRole(.row)
    }

    private var kind: PlacesPanel.RowKind? {
        guard let panel, panel.rows.indices.contains(index) else { return nil }
        return panel.rows[index].kind
    }

    override func accessibilityLabel() -> String? {
        switch kind {
        case .header(let s): return PlacesModel.shared.title(of: s)
        case .entry(let e): return e.title
        case nil: return nil
        }
    }

    override func accessibilityRoleDescription() -> String? {
        if case .header = kind { return "section" }
        return "place"
    }

    override func isAccessibilityDisclosed() -> Bool {
        guard case .header(let s) = kind else { return false }
        return !PlacesModel.shared.collapsedSections.contains(s)
    }

    override func isAccessibilitySelected() -> Bool {
        guard case .entry(let e) = kind, let current = panel?.currentURL else { return false }
        return e.url.standardizedFileURL == current.standardizedFileURL
    }

    override func accessibilityFrameInParentSpace() -> NSRect { panel.map { $0.rect(of: index) } ?? .zero }

    override func accessibilityFrame() -> NSRect {
        guard let panel, let window = panel.window else { return .zero }
        return window.convertToScreen(panel.convert(panel.rect(of: index), to: nil))
    }

    /// VO-Shift-M: the place's context menu (Eject, Remove, Edit…), as a secondary click shows it.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let panel, let window = panel.window, panel.rows.indices.contains(index) else { return false }
        let r = panel.rect(of: index)
        guard
            let e = NSEvent.mouseEvent(
                with: .rightMouseDown, location: panel.convert(CGPoint(x: r.midX, y: r.midY), to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
            let menu = panel.menu(for: e)
        else { return false }
        if let present = Self.presentForTesting { present(menu) } else { NSMenu.popUpContextMenu(menu, with: e, for: panel) }
        return true
    }

    nonisolated(unsafe) static var presentForTesting: ((NSMenu) -> Void)?

    /// The same row, while it shows the same thing: VoiceOver keeps its place across the panel's redraws.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PlaceAccessibilityElement, other.panel === panel else { return false }
        return other.identity == identity
    }
    override var hash: Int { identity.hashValue }

    private var identity: String {
        switch kind {
        case .header(let s): return "section:\(s.rawValue)"
        case .entry(let e): return "place:\(e.url.absoluteString)|\(e.section.rawValue)"
        case nil: return "gone:\(index)"
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let panel else { return false }
        switch kind {
        case .header(let s): panel.toggleSectionAnimated(s)
        case .entry(let e): panel.delegate?.places(panel, open: e.url, newTab: false, splitView: false)
        case nil: return false
        }
        return true
    }
}
