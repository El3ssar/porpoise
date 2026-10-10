import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Panels

extension MainWindowController {
    /// Smallest sidebar width when dragging its divider.
    private static let minPanelDividerPosition: CGFloat = 150
    /// Share of the sidebar height Places gets when Folders is shown below it.
    private static let placesShareOfSidebar: CGFloat = 0.55

    private var sidebarVisible: Bool { showPlaces || showFolders }

    /// Re-arranges the panel split views according to which panels are visible.
    func rebuildPanels() {
        // The split views pass through transient sizes while being rebuilt; don't remember those.
        rebuildingPanels = true
        defer { rebuildingPanels = false }
        for s in [outer, hSplit, vSplit, leftStack] {
            s.arrangedSubviews.forEach {
                s.removeArrangedSubview($0); $0.removeFromSuperview()
            }
        }
        if showPlaces { leftStack.addArrangedSubview(placesScroll) }
        if showFolders { leftStack.addArrangedSubview(folders) }
        if sidebarVisible {
            outer.addArrangedSubview(sidebar)
            sidebarMaterial.frame = sidebar.bounds
            layoutSidebar()
        }
        outer.addArrangedSubview(mainColumn)
        hSplit.addArrangedSubview(centerColumn)
        if showInformation { hSplit.addArrangedSubview(information) }
        vSplit.addArrangedSubview(hSplit)
        if showTerminal { vSplit.addArrangedSubview(terminal) }
        // Panels hold their size when the window resizes; the views take up the difference.
        for (i, v) in outer.arrangedSubviews.enumerated() { outer.setHoldingPriority(v === mainColumn ? .defaultLow : .init(270), forSubviewAt: i) }
        for (i, v) in hSplit.arrangedSubviews.enumerated() {
            hSplit.setHoldingPriority(v === centerColumn ? .defaultLow : .init(261), forSubviewAt: i)
        }
        for (i, v) in vSplit.arrangedSubviews.enumerated() { vSplit.setHoldingPriority(v === hSplit ? .defaultLow : .init(260), forSubviewAt: i) }
        layoutRoot()
        outer.layoutSubtreeIfNeeded()
        // Newly added panels arrive with empty frames; give every split its full extent before placing dividers
        // (setPosition only moves space between neighbours, so two zero-sized neighbours would stay at zero).
        for split in [outer, hSplit, vSplit] { split.adjustSubviews() }
        if sidebarVisible {
            outer.setPosition(PanelSize.sidebarWidth.fitted(in: outer.bounds.width, divider: outer.dividerThickness), ofDividerAt: 0)
        }
        mainColumn.layoutSubtreeIfNeeded()
        vSplit.layoutSubtreeIfNeeded()
        if showInformation {
            let w = hSplit.bounds.width, d = hSplit.dividerThickness
            hSplit.setPosition(w - PanelSize.informationWidth.fitted(in: w, divider: d) - d, ofDividerAt: 0)
        }
        if showTerminal {
            let h = vSplit.bounds.height, d = vSplit.dividerThickness
            vSplit.setPosition(h - PanelSize.terminalHeight.fitted(in: h, divider: d) - d, ofDividerAt: 0)
        }
        if showPlaces && showFolders { leftStack.setPosition(leftStack.bounds.height * Self.placesShareOfSidebar, ofDividerAt: 0) }
        for t in tabs { t.navigators.forEach { $0.showPlacesButton = !showPlaces } }
        if tabs.indices.contains(current) {
            if showFolders { folders.currentURL = view.url }
            if showInformation { information.show(hovered: nil, container: view) }
            if showTerminal { terminal.follow(view.url) }
        }
        Settings.store.set(showPlaces, forKey: "panel.places")
        Settings.store.set(showFolders, forKey: "panel.folders")
        Settings.store.set(showInformation, forKey: "panel.info")
        Settings.store.set(showTerminal, forKey: "panel.terminal")
        alignNavigators()
    }

    enum PanelSlot { case sidebar, information, terminal }

    /// Shows or hides a panel with a slide (macOS-style), then rebuilds the layout.
    /// `toggle` flips the visibility flag(s); a sidebar change that keeps the sidebar visible just rebuilds.
    func animatePanel(_ slot: PanelSlot, show: Bool, toggle: @escaping () -> Void) {
        finishPanelSlide()
        if slot == .sidebar {
            let sidebarWasVisible = sidebarVisible
            toggle()
            if sidebarWasVisible == sidebarVisible { rebuildPanels(); return }
            if sidebarVisible {
                rebuildPanels(); slide(slot, opening: true)
            } else {
                // Put the flag back while sliding out, then apply.
                toggle();
                slide(slot, opening: false) {
                    toggle(); self.rebuildPanels()
                }
            }
            return
        }
        if show {
            toggle(); rebuildPanels(); slide(slot, opening: true)
        } else {
            slide(slot, opening: false) {
                toggle(); self.rebuildPanels()
            }
        }
    }

    /// Ends the running panel slide at once, applying what it was going to apply.
    private func finishPanelSlide() {
        panelAnimator.stop()
        animatingPanels = false
        let completion = pendingSlideCompletion
        pendingSlideCompletion = nil
        completion?()
    }

    /// Places/Folders sit below the title bar area; the strip above them (with the traffic lights) drags the window.
    func layoutSidebar() {
        let th = window?.styleMask.contains(.fullScreen) == true ? 0 : Theme.toolbarHeight
        leftStack.frame = CGRect(x: 0, y: 0, width: sidebar.bounds.width, height: max(0, sidebar.bounds.height - th))
    }

    /// Animates the divider of `slot`'s split view between collapsed and the panel's remembered size.
    private func slide(_ slot: PanelSlot, opening: Bool, completion: (() -> Void)? = nil) {
        let split = slot == .terminal ? vSplit : (slot == .sidebar ? outer : hSplit)
        let count = split.arrangedSubviews.count
        guard count > 1 else { completion?(); return }
        split.layoutSubtreeIfNeeded()
        let d = split.dividerThickness
        let divider: Int, collapsed: CGFloat, open: CGFloat, current: CGFloat
        switch slot {
        case .terminal:
            divider = 0
            collapsed = split.bounds.height
            open = collapsed - PanelSize.terminalHeight.fitted(in: collapsed, divider: d) - d
            current = collapsed - split.arrangedSubviews[1].frame.height - d
        case .information:
            divider = count - 2
            collapsed = split.bounds.width
            open = collapsed - PanelSize.informationWidth.fitted(in: collapsed, divider: d) - d
            current = collapsed - split.arrangedSubviews[count - 1].frame.width - d
        case .sidebar:
            divider = 0
            collapsed = 0
            open = PanelSize.sidebarWidth.fitted(in: split.bounds.width, divider: d)
            current = split.arrangedSubviews[0].frame.width
        }
        let from = opening ? collapsed : current
        let target = opening ? open : collapsed
        animatingPanels = true
        pendingSlideCompletion = completion
        split.setPosition(from, ofDividerAt: divider)
        panelAnimator.run(
            duration: opening ? 0.22 : 0.18, curve: opening ? Animator.easeOutCubic : Animator.easeInCubic,
            step: { p in
                split.setPosition(from + (target - from) * CGFloat(p), ofDividerAt: divider)
            },
            completion: { [weak self] in
                self?.finishPanelSlide()
            })
    }

    func splitViewDidResizeSubviews(_ n: Notification) {
        guard let sv = n.object as? NSSplitView, sv === hSplit || sv === vSplit || sv === outer else { return }
        let id = ObjectIdentifier(sv)
        let last = splitStates[id]
        let resized = last?.size != sv.bounds.size
        let moved = last?.panel != panelExtent(in: sv)
        if !animatingPanels && !rebuildingPanels && !fittingPanels {
            // The split itself changed size (window resize, a neighbouring panel moved): its panel keeps its size as
            // far as the files leave room. Its panel changed size in a split of the same size: the user dragged
            // the divider, so remember the new size. (Splits also report resizes in which nothing changed.)
            if resized { fitPanel(of: sv) } else if moved { savePanelSize(of: sv) }
        }
        splitStates[id] = (sv.bounds.size, panelExtent(in: sv))
        if sv === outer { layoutToolbar(); layoutSidebar() }
        alignNavigators()
    }

    /// Width (height for the terminal) of the panel held by `sv`, nil while it holds none.
    private func panelExtent(in sv: NSSplitView) -> CGFloat? {
        if sv === outer { return outer.arrangedSubviews.first === sidebar ? sidebar.frame.width : nil }
        if sv === hSplit { return hSplit.arrangedSubviews.last === information ? information.frame.width : nil }
        if sv === vSplit { return vSplit.arrangedSubviews.last === terminal ? terminal.frame.height : nil }
        return nil
    }

    /// For tests: frames of the panel splits' children.
    var debugSplitFrames: [String] {
        [outer, hSplit, vSplit].map { sv in
            "\(type(of: sv)) \(Int(sv.bounds.width))x\(Int(sv.bounds.height)): "
                + sv.arrangedSubviews.map {
                    "\(type(of: $0))=\(Int($0.frame.minX)),\(Int($0.frame.width))x\(Int($0.frame.height))\($0.isHidden ? " hidden" : "")"
                }.joined(separator: " ")
        }
    }

    /// Gives `sv`'s panel the size it should have at the split's current size (`PanelSize.fitted`): its remembered
    /// size, smaller while the window is too small for it and the files, and back again when the window grows.
    /// Window setup lays the splits out while the window is still zero-sized, and only the files area follows
    /// later resizes, so without this a panel could stay at zero, swallow the files, or stay shrunk.
    private func fitPanel(of sv: NSSplitView) {
        fittingPanels = true
        defer { fittingPanels = false }
        let d = sv.dividerThickness
        if sv === outer, sidebarVisible, outer.arrangedSubviews.first === sidebar {
            let target = PanelSize.sidebarWidth.fitted(in: outer.bounds.width, divider: d)
            if abs(sidebar.frame.width - target) > 0.5 { outer.setPosition(target, ofDividerAt: 0) }
        } else if sv === hSplit, showInformation, hSplit.arrangedSubviews.last === information {
            let w = hSplit.bounds.width, target = PanelSize.informationWidth.fitted(in: w, divider: d)
            if abs(information.frame.width - target) > 0.5 { hSplit.setPosition(w - target - d, ofDividerAt: hSplit.arrangedSubviews.count - 2) }
        } else if sv === vSplit, showTerminal, vSplit.arrangedSubviews.last === terminal {
            let h = vSplit.bounds.height, target = PanelSize.terminalHeight.fitted(in: h, divider: d)
            if abs(terminal.frame.height - target) > 0.5 { vSplit.setPosition(h - target - d, ofDividerAt: vSplit.arrangedSubviews.count - 2) }
        }
    }

    private func savePanelSize(of sv: NSSplitView) {
        if sv === outer, sidebarVisible, outer.arrangedSubviews.first === sidebar {
            PanelSize.sidebarWidth.save(sidebar.frame.width, in: outer.bounds.width)
        } else if sv === hSplit, showInformation {
            PanelSize.informationWidth.save(information.frame.width, in: hSplit.bounds.width)
        } else if sv === vSplit, showTerminal {
            PanelSize.terminalHeight.save(terminal.frame.height, in: vSplit.bounds.height)
        }
    }

    /// Panels keep their size when the window resizes; only the views (and the panel splits holding them) adjust.
    /// The panel splits are framed by hand, so NSSplitView's proportional resizing applies, not holding priorities.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === mainColumn || view === centerColumn || view === hSplit
    }

    /// Divider drags stay within the sizes a panel may have (see `PanelSize.dividerRange`), so the files keep room
    /// and the dragged size is one that is remembered.
    private func dragRange(_ splitView: NSSplitView) -> ClosedRange<CGFloat>? {
        let d = splitView.dividerThickness
        if splitView === outer {
            let r = PanelSize.sidebarWidth.dividerRange(in: splitView.bounds.width, divider: d)
            let lo = min(max(r.lowerBound, Self.minPanelDividerPosition), r.upperBound)
            return lo...r.upperBound
        }
        if splitView === hSplit { return PanelSize.informationWidth.dividerRange(in: splitView.bounds.width, divider: d) }
        if splitView === vSplit { return PanelSize.terminalHeight.dividerRange(in: splitView.bounds.height, divider: d) }
        return nil
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if animatingPanels { return p }
        return dragRange(splitView).map { max(p, $0.lowerBound) } ?? p
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if animatingPanels { return p }
        return dragRange(splitView).map { min(p, $0.upperBound) } ?? p
    }
}
