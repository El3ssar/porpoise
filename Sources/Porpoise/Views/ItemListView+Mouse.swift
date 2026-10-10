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
        hoveredURL = item?.url
        if let item, hoverAlpha[item.url] == nil { hoverAlpha[item.url] = 0.01 }
        startHoverAnimation()
        delegate?.itemList(self, hovered: item)
        if Settings.shared.showToolTips, let it = item {
            toolTip = "\(it.name)\n\(it.typeDescription)\n" + (it.isBrowsableFolder ? model.folderSizeText(it) : FileFormat.size(it.size))
        } else {
            toolTip = nil
        }
    }

    /// Hover highlight fades (Breeze animates hover; ~120 ms in, ~200 ms out).
    private func startHoverAnimation() {
        guard hoverTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 90, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let rows = self.model.rows
            let target = self.hoverIndex.flatMap { $0 < rows.count ? rows[$0].item.url : nil }
            var done = true
            for (u, a) in self.hoverAlpha {
                let goal: CGFloat = u == target ? 1 : 0
                let next = goal > a ? min(1, a + 0.13) : max(0, a - 0.08)
                if next == 0 && goal == 0 { self.hoverAlpha.removeValue(forKey: u) } else { self.hoverAlpha[u] = next }
                if next != goal { done = false }
                if let i = self.model.index(of: u), i < self.frames.count { self.setNeedsDisplay(self.highlightRect(i).insetBy(dx: -30, dy: -4)) }
            }
            if done { t.invalidate(); self.hoverTimer = nil }
        }
        hoverTimer = t
        RunLoop.main.add(t, forMode: .common)
    }
}

// MARK: - Clicks, rubber band, context menu

extension ItemListView {
    override func mouseDown(with event: NSEvent) {
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
            if !mods.contains(.command) && !mods.contains(.shift) { model.selection = [] }
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
        if mods.contains(.shift), let anchor = model.anchorURL, let a = model.index(of: anchor) {
            let urls = Set((min(a, i)...max(a, i)).map { model.rows[$0].item.url })
            model.selection = mods.contains(.command) ? model.selection.union(urls) : urls
        } else if mods.contains(.command) {
            if model.selection.contains(url) { model.selection.remove(url) } else { model.selection.insert(url) }
            model.anchorURL = url
        } else if !model.selection.contains(url) {
            model.selection = [url]
            model.anchorURL = url
        }
        model.currentURL = url
        needsDisplay = true
    }

    /// Finder: clicking the cloud badge of an item that is only in the cloud downloads it.
    private func downloadFromCloudBadge(at p: CGPoint) -> Bool {
        guard let i = cloudRects.first(where: { $0.value.contains(p) })?.key, i < model.rows.count,
            model.cloud(for: model.rows[i].item).state == .cloudOnly
        else { return false }
        CloudActions.download([model.rows[i].item.url])
        model.refreshCloud()
        needsDisplay = true
        return true
    }

    /// Adds or removes one item, making it the current item and the anchor for Shift ranges.
    func toggleSelected(_ url: URL) {
        if model.selection.contains(url) { model.selection.remove(url) } else { model.selection.insert(url) }
        model.currentURL = url
        model.anchorURL = url
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
            let url = model.rows[i].item.url
            if mouseDownSelectedBefore && model.selection.count > 1 { model.selection = [url] }
            model.anchorURL = url
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
        let p = convert(event.locationInWindow, from: nil)
        if let i = index(at: p) {
            let url = model.rows[i].item.url
            if !model.selection.contains(url) { model.selection = [url] }
            model.currentURL = url
            needsDisplay = true
            return delegate?.itemList(self, menuFor: model.rows[i].item)
        }
        model.selection = []
        needsDisplay = true
        return delegate?.itemList(self, menuFor: nil)
    }
}

// MARK: - Gestures (Cmd+wheel and pinch zoom, swipe back/forward)

extension ItemListView {
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // Cmd+wheel / two-finger scroll zooms smoothly (trackpads) or by Dolphin's steps (mouse wheels).
            let p = convert(event.locationInWindow, from: nil)
            if event.hasPreciseScrollingDeltas {
                let level = ZoomLevels.continuousLevel(for: iconSize) + Double(event.scrollingDeltaY) * 0.02
                previewZoom(ZoomLevels.size(forContinuousLevel: level), anchor: p)
            } else if event.scrollingDeltaY != 0 {
                previewZoom(ZoomLevels.step(from: iconSize, by: event.scrollingDeltaY > 0 ? 1 : -1), anchor: p)
            }
            return
        }
        super.scrollWheel(with: event)
        // The content moved under a still pointer.
        if let w = window {
            hoverIndex = index(at: convert(w.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func magnify(with event: NSEvent) {
        // Pinch: continuous zoom around the fingers, saved when the gesture ends.
        let p = convert(event.locationInWindow, from: nil)
        previewZoom(iconSize * (1 + event.magnification), anchor: p, commitAfter: event.phase == .ended || event.phase == .cancelled ? 0 : 0.5)
    }

    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 {
            NSApp.sendAction(#selector(MainWindowController.goBack(_:)), to: nil, from: self)
        } else if event.deltaX < 0 {
            NSApp.sendAction(#selector(MainWindowController.goForward(_:)), to: nil, from: self)
        }
    }
}
