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
        case .entry(let e):
            if let pair = SyncCoordinator.shared.pair(for: e.url) { return pair.name + ", " + SyncCoordinator.shared.tooltip(pair) }
            return e.title
        case nil: return nil
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard case .header(.sync) = kind, let panel else { return nil }
        return [SyncAddAccessibilityElement(panel: panel, index: index)]
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
        guard case .entry(let e) = kind else { return false }
        return panel?.isCurrent(e) ?? false
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
        case .entry(let e): panel.openPlace(e, newTab: false)
        case nil: return false
        }
        return true
    }
}

private final class SyncAddAccessibilityElement: NSAccessibilityElement {
    private weak var panel: PlacesPanel?
    private let index: Int
    init(panel: PlacesPanel, index: Int) {
        self.panel = panel; self.index = index; super.init()
        setAccessibilityParent(panel); setAccessibilityRole(.button); setAccessibilityLabel("New Sync…")
    }
    override func accessibilityFrame() -> NSRect {
        guard let panel, let window = panel.window else { return .zero }
        let row = panel.rect(of: index)
        let box = CGRect(x: row.maxX - 56, y: row.minY, width: 28, height: row.height)
        return window.convertToScreen(panel.convert(box, to: nil))
    }
    override func accessibilityPerformPress() -> Bool {
        guard let panel else { return false }
        SyncCoordinator.shared.create(window: panel.window, left: panel.currentURL); return true
    }
}
