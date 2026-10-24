import AppKit
import PorpoiseServices

extension MainWindowController {
    /// The Information panel at the window's right edge, right of the files (both panes of a split): added or removed
    /// beside the center column only, so the file panes stay where they are (scroll position, selection, a rename in
    /// progress, a playing video). Which pane is active changes only what it shows, never where it is.
    func syncInformationPanel() {
        guard tabs.indices.contains(current) else { return }
        let wasRebuilding = rebuildingPanels
        rebuildingPanels = true
        defer { rebuildingPanels = wasRebuilding }
        guard showInformation else {
            if information.superview === hSplit { hSplit.removeArrangedSubview(information) }
            information.removeFromSuperview()
            return
        }
        if information.superview !== hSplit {
            let responder = window?.firstResponder
            hSplit.addArrangedSubview(information)
            hSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            hSplit.setHoldingPriority(.init(261), forSubviewAt: 1)
            hSplit.adjustSubviews()
            let width = hSplit.bounds.width, divider = hSplit.dividerThickness
            hSplit.setPosition(width - PanelSize.informationWidth.fitted(in: width, divider: divider) - divider, ofDividerAt: 0)
            hSplit.layoutSubtreeIfNeeded()
            if let responder { window?.makeFirstResponder(responder) }
        }
        information.show(hovered: nil, container: view)
    }
}
