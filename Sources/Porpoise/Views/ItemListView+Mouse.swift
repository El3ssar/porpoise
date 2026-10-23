import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Hover

extension ItemListView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p)
        let onMarker = i.map { Settings.shared.showSelectionMarker && markerRect($0).contains(p) } ?? false
        if onMarker != hoverOnMarker, let i { hoverOnMarker = onMarker; setNeedsDisplay(frames[i].insetBy(dx: -30, dy: -2)) }
        hoverIndex = i
        updateBadgeTip(at: p, row: i)
    }

    /// Over a cloud badge the tooltip says what it means ("Kept downloaded on this Mac."); off it, the item's again.
    private func updateBadgeTip(at p: CGPoint, row i: Int?) {
        let help = i.flatMap { i in
            cloudRects[i].flatMap { $0.contains(p) ? CloudBadge.help(cloudBadge(model.rows[i].item), of: model.rows[i].item.url) : nil }
        }
        if let help {
            if toolTip != help { toolTip = help }
            badgeTipShown = true
        } else if badgeTipShown {
            badgeTipShown = false
            hoverChanged(hoverIndex)
        }
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    /// The rows changed (reload, sort, filter…) under a still pointer: hover what is under it now, so the status bar
    /// and the Information panel don't keep describing an item that moved away or no longer exists.
    func refreshHover() {
        guard let w = window, w.isKeyWindow || hoverIndex != nil else { return }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        let i = w.isKeyWindow && visibleRect.contains(p) ? index(at: p) : nil
        let url = i.map { model.rows[$0].item.url }
        if i != hoverIndex { hoverIndex = i } else if url != hoveredURL { hoverChanged(hoverIndex) }
    }

    /// Called by `hoverIndex`: repaint, start the fade, tell the delegate (status bar, Information panel).
    func hoverChanged(_ old: Int?) {
        for i in [old, hoverIndex].compactMap({ $0 }) where i < frames.count {
            setNeedsDisplay(highlightRect(i).insetBy(dx: -30, dy: -4))
        }
        let item = hoverIndex.flatMap { $0 < model.rows.count ? model.rows[$0].item : nil }
        model.prefetch(item)
        hoveredURL = item?.url
        hoverFade.update()
        delegate?.itemList(self, hovered: item)
        let line = item.flatMap(model.searchSnippet(for:)).map { "“\($0)”" }
        if Settings.shared.showToolTips, let it = item {
            toolTip =
                "\(it.name)\n\(it.typeDescription)\n" + (it.isBrowsableFolder ? model.folderSizeText(it) : FileFormat.size(it.size))
                + (line.map { "\n\n" + $0 } ?? "")
        } else {
            // The whole line of a content match, which the row may cut short; else a name elided in its column.
            toolTip = line ?? hoverIndex.flatMap(elidedName)
        }
    }

    /// The name of row `i` when its one-line label (Compact, Details) cuts it short.
    private func elidedName(_ i: Int) -> String? {
        guard mode != .icons, i < model.rows.count else { return nil }
        let name = model.displayName(for: model.rows[i].item)
        return textWidth(name) > nameTextRect(i).width ? name : nil
    }
}

// MARK: - Clicks, rubber band, context menu

extension ItemListView {
    /// Clicks, Shift and Cmd, and moves of the current item, as in the Applications grid.
    var selecting: ItemSelectionController { ItemSelectionController(model: model) }

    override func mouseDown(with event: NSEvent) {
        if SecondaryClick.matches(event) {
            mouseDownIndex = nil
            rubberStart = nil
            rubberBand = nil
            SecondaryClick.present(event, in: self)
            return
        }
        window?.makeFirstResponder(self)
        commitRename()
        let p = convert(event.locationInWindow, from: nil)
        if downloadFromCloudBadge(at: p) { return }
        mouseDownPoint = p
        let idx = index(at: p)
        mouseDownIndex = idx
        let mods = event.modifierFlags

        if event.clickCount == 2 {
            if let i = idx {
                if expanderRect(i)?.contains(p) == true { return }
                delegate?.itemList(self, open: [model.rows[i].item], inNewTab: false)
            } else {
                delegate?.itemListBackgroundDoubleClicked(self)
            }
            return
        }

        guard let i = idx else {
            // Background: start a rubber band.
            selecting.clickBackground(modifiers: mods)
            rubberBaseSelection = model.selection
            rubberStart = p
            needsDisplay = true
            return
        }
        let url = model.rows[i].item.url
        // Expander and marker clicks are complete here: mouseUp must not treat them as an item click.
        if let er = expanderRect(i), er.insetBy(dx: -2, dy: -2).contains(p) {
            model.toggleExpanded(url)
            mouseDownIndex = nil
            return
        }
        if Settings.shared.showSelectionMarker && markerRect(i).contains(p) {
            toggleSelected(url)
            mouseDownIndex = nil
            return
        }
        mouseDownSelectedBefore = model.selection.contains(url)
        if selectionModeActive && !mods.contains(.shift) {
            toggleSelected(url)
            mouseDownIndex = nil
            return
        }
        selecting.click(i, modifiers: mods)
        needsDisplay = true
    }

    /// Finder: clicking the cloud badge of an item that is only in the cloud downloads it; a problem badge shows
    /// Activity, where it's explained.
    private func downloadFromCloudBadge(at p: CGPoint) -> Bool {
        guard let i = cloudRects.first(where: { $0.value.contains(p) })?.key, i < model.rows.count,
            case .cloud(let state) = cloudBadge(model.rows[i].item)
        else { return false }
        if case .error = state {
            ActivityWindowController.shared.show()
            return true
        }
        guard state == .cloudOnly else { return false }
        KeepDownloadedSheet.download([model.rows[i].item], window: window)
        model.refreshCloud()
        needsDisplay = true
        return true
    }

    /// Adds or removes one item, making it the current item and the anchor for Shift ranges.
    func toggleSelected(_ url: URL) {
        selecting.toggle(url)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let start = rubberStart {
            updateRubberBand(
                CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)),
                toggling: event.modifierFlags.contains(.command))
            autoscroll(with: event)
            return
        }
        if let i = mouseDownIndex, hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y) > 4 {
            mouseDownIndex = nil
            startDrag(from: i, event: event)
        }
    }

    /// Selection = what was selected before the band, plus the items it touches (Cmd: toggles them instead).
    private func updateRubberBand(_ r: CGRect, toggling: Bool) {
        rubberBand = r
        var sel = rubberBaseSelection
        for i in candidateIndexes(in: r) where highlightRect(i).intersects(r) {
            let u = model.rows[i].item.url
            if toggling && rubberBaseSelection.contains(u) { sel.remove(u) } else { sel.insert(u) }
        }
        model.selection = sel
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !SecondaryClick.matches(event) else { mouseDownIndex = nil; return }
        if rubberStart != nil {
            rubberStart = nil
            rubberBand = nil
            needsDisplay = true
            return
        }
        // Click on an already selected item without modifiers: select just that one.
        if let i = mouseDownIndex, i < model.rows.count, event.clickCount == 1, !event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.shift)
        {
            selecting.clickEnded(i, wasSelected: mouseDownSelectedBefore)
            needsDisplay = true
        }
        mouseDownIndex = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 2:
            let p = convert(event.locationInWindow, from: nil)
            if let i = index(at: p) { delegate?.itemList(self, middleClicked: model.rows[i].item) }
        case 3: NSApp.sendAction(#selector(MainWindowController.goBack(_:)), to: nil, from: self)
        case 4: NSApp.sendAction(#selector(MainWindowController.goForward(_:)), to: nil, from: self)
        default: break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let i = index(at: convert(event.locationInWindow, from: nil))
        selecting.contextClick(i)
        needsDisplay = true
        return delegate?.itemList(self, menuFor: i.map { model.rows[$0].item })
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
}

// MARK: - Gestures (Cmd+wheel and pinch zoom, swipe back/forward)

extension ItemListView {
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let target = columnNavigator?.zoomTarget(from: self), target !== self {
            return target.scrollWheel(with: event)
        }
        if zoomWithWheel(event) { return }
        super.scrollWheel(with: event)
        // The content moved under a still pointer.
        if let w = window {
            hoverIndex = index(at: convert(w.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func magnify(with event: NSEvent) {
        // Column view: another column's zoom is the focused column's, the focus moving there first.
        if let target = columnNavigator?.zoomTarget(from: self), target !== self { return target.magnify(with: event) }
        zoomWithPinch(event)
    }

    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 {
            NSApp.sendAction(#selector(MainWindowController.goBack(_:)), to: nil, from: self)
        } else if event.deltaX < 0 {
            NSApp.sendAction(#selector(MainWindowController.goForward(_:)), to: nil, from: self)
        }
    }
}
