import AppKit
import PorpoiseServices

private final class InformationGhost: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension MainWindowController {
    func finishInformationMove() {
        guard informationGhost != nil || informationMoveAnimator.isRunning else { return }
        informationMoveAnimator.stop()
        informationGhost?.removeFromSuperview()
        informationGhost = nil
        information.alphaValue = 1
        informationTab?.containers.forEach { $0.list.transitions.releaseWidth() }
    }

    /// One inspector per window, beside the highlighted pane. Its host occupies that pane's share of the tab,
    /// so opening it never steals space from the other pane or moves the split handle.
    func syncInformationPanel() {
        guard tabs.indices.contains(current) else { return }
        let owner = showInformation ? tab : nil
        if informationTab === owner, owner == nil || owner?.informationPane === view { return }
        if panelAnimator.isRunning { finishPanelSlide() }
        finishInformationMove()
        // A crossfade hands the inspector to the newly highlighted pane without a distracting flight across the
        // files. A small snapshot covers only the old inspector; file icons glide to their new positions once.
        let moving = showInformation && informationTab === tab && tab.informationPane != nil && !Animator.reducesMotion()
        var ghost: InformationGhost?
        if moving, let rep = information.bitmapImageRepForCachingDisplay(in: information.bounds) {
            information.cacheDisplay(in: information.bounds, to: rep)
            let image = NSImage(size: information.bounds.size)
            image.addRepresentation(rep)
            let copy = InformationGhost(frame: root.convert(information.bounds, from: information))
            copy.image = image
            copy.imageScaling = .scaleAxesIndependently
            copy.setAccessibilityElement(false)
            root.addSubview(copy)
            ghost = copy
            tab.containers.forEach { $0.list.transitions.holdForPanel() }
        }
        let wasRebuilding = rebuildingPanels
        rebuildingPanels = true
        defer { rebuildingPanels = wasRebuilding }
        if informationTab !== owner {
            informationTab?.dockInformation(in: nil)
            informationTab = nil
        }
        guard showInformation else {
            information.removeFromSuperview()
            return
        }
        informationTab = tab
        if informationSpace.superview !== hSplit { hSplit.insertArrangedSubview(informationSpace, at: 0) }
        if information.superview !== hSplit { hSplit.addArrangedSubview(information) }
        tab.dockInformation(in: hSplit)
        hSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        hSplit.setHoldingPriority(.init(261), forSubviewAt: 1)
        hSplit.adjustSubviews()
        let width = hSplit.bounds.width, divider = hSplit.dividerThickness
        hSplit.setPosition(width - PanelSize.informationWidth.fitted(in: width, divider: divider) - divider, ofDividerAt: 0)
        hSplit.layoutSubtreeIfNeeded()
        tab.layoutInformationFiles()
        information.show(hovered: nil, container: view)
        if let ghost {
            informationGhost = ghost
            information.alphaValue = 0
            tab.containers.forEach { $0.list.transitions.glideForPanel(duration: Motion.fade, curve: Animator.easeOutCubic) }
            informationMoveAnimator.run(
                duration: Motion.fade, curve: Animator.easeOutCubic,
                step: { [weak self, weak ghost] p in
                    self?.information.alphaValue = p
                    ghost?.alphaValue = 1 - p
                }, completion: { [weak self] in self?.finishInformationMove() })
        }
    }
}
