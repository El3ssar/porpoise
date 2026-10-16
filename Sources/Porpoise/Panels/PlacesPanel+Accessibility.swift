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
        case .header(let s): return s.rawValue
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
