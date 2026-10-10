import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Drawing

extension ItemListView {
    override func draw(_ dirty: NSRect) {
        // Inactive split pane: View color at alpha 150/255 over the window color (measured #1a1e2a).
        let bg = isActiveView ? Theme.viewBackground : Theme.inactiveViewBackgroundOpaque
        bg.setFill()
        dirty.fill()
        if frames.count != model.rows.count { computeLayout() }

        for (gi, gr) in groupHeaderFrames.enumerated() where gr.intersects(dirty) && gi < model.groups.count {
            drawGroupHeader(model.groups[gi].title, in: gr)
        }
        for i in candidateIndexes(in: dirty.insetBy(dx: -40, dy: -4)) {
            drawItem(i)
        }
        if let rb = rubberBand {
            let path = NSBezierPath(rect: rb.insetBy(dx: 0.5, dy: 0.5))
            Theme.selection.withAlphaComponent(0.35).setFill()
            path.fill()
            Theme.selection.lighter(130).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        if dropOnBackground {
            let r = visibleRect.insetBy(dx: 2, dy: 2)
            let p = NSBezierPath(roundedRect: r, xRadius: Theme.frameRadius, yRadius: Theme.frameRadius)
            Theme.focus.setStroke(); p.lineWidth = 2; p.stroke()
        }
        if model.rows.isEmpty { drawPlaceholder() }
    }

    private func drawPlaceholder() {
        let text: String
        if model.isLoading && model.items.isEmpty {
            text = "Loading…"
        } else if let e = model.loadError {
            text = e
        } else if model.isSearching {
            text = "No items matching the search"
        } else if model.filter.isActive {
            text = "No items matching the filter"
        } else if model.location.path == FileManager.default.homeDirectoryForCurrentUser.path + "/.Trash" {
            text = "Trash is empty"
        } else {
            text = "Folder is empty"
        }
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: Theme.viewTextInactive.withAlphaComponent(0.8), .paragraphStyle: p,
        ]
        let vr = visibleRect
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            in: CGRect(x: vr.minX, y: vr.midY - s.height / 2 - 20, width: vr.width, height: s.height + 4),
            withAttributes: attrs)
    }

    private func drawGroupHeader(_ title: String, in r: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Theme.fontSize, weight: .semibold),
            .foregroundColor: Theme.viewText,
        ]
        let s = (title as NSString).size(withAttributes: attrs)
        let ty = r.minY + (r.height - s.height) / 2 + 2
        (title as NSString).draw(at: CGPoint(x: r.minX + 4, y: ty), withAttributes: attrs)
        let lineY = floor(r.maxY - 3) + 0.5
        let line = NSBezierPath()
        line.move(to: CGPoint(x: r.minX + 2, y: lineY))
        line.line(to: CGPoint(x: r.maxX - 2, y: lineY))
        Theme.viewText.withAlphaComponent(0.25).setStroke()
        line.lineWidth = 1
        line.stroke()
    }

    // MARK: Items

    private func drawItem(_ i: Int) {
        let item = model.rows[i].item
        let selected = model.selection.contains(item.url)

        if mode == .details {
            // Alternating row colors (Dolphin draws them across the whole view width).
            if i % 2 == 1 {
                Theme.viewAlternate.setFill()
                CGRect(x: 0, y: frames[i].minY, width: bounds.width, height: frames[i].height).fill()
            }
            if expanderWidth > 0, i < treeLines.count { drawTreeLines(i) }
        }
        drawItemBackground(i, selected: selected)
        if let er = expanderRect(i) {
            let name = model.rows[i].isExpanded ? "go-down" : "go-next"
            if let img = Icons.shared.image(name, size: 16, selected: selected) {
                img.draw(in: er, from: .zero, operation: .sourceOver, fraction: 0.85)
            }
        }
        let (image, imageRect) = drawIcon(i)
        let cloud = model.shownCloud(for: item).state
        drawCloudBadge(cloud, row: i, image: image, imageRect: imageRect, selected: selected)
        if item.isSymlink || item.isAliasFile { drawLinkEmblem(i, besideCloudBadge: cloud != .local) }

        // Selection marker (Dolphin's +/- toggle on hover)
        if hoverIndex == i && Settings.shared.showSelectionMarker && rubberBand == nil && renamingItem == nil {
            drawSelectionMarker(in: markerRect(i), selected: selected)
        }

        let isRenamingThis = renamingItem?.url == item.url
        switch mode {
        case .icons: if !isRenamingThis { drawIconsText(i, selected: selected) }
        case .compact: if !isRenamingThis { drawCompactText(i, selected: selected) }
        case .details: drawDetailsText(i, selected: selected, showName: !isRenamingThis)
        }
    }

    /// Breeze item background: selected, hovered (fading), drop target, or the focus frame of the current item.
    private func drawItemBackground(_ i: Int, selected: Bool) {
        let url = model.rows[i].item.url
        let isDrop = dropTargetIndex == i
        let hoverT = hoverAlpha[url] ?? 0
        let path = NSBezierPath(roundedRect: highlightRect(i).insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.itemRadius, yRadius: Theme.itemRadius)
        path.lineWidth = 1
        if selected || hoverT > 0 || isDrop {
            let fill: NSColor
            if selected {
                let base = isActiveView && window?.isKeyWindow != false ? Theme.itemSelectedFill : Theme.itemSelectedFill.withAlphaComponent(0.6)
                fill = base.mixed(with: Theme.itemSelectedHoverFill, hoverT)
            } else {
                fill = isDrop ? Theme.itemSelectedFill : Theme.itemHoverFill.withAlphaComponent(Theme.itemHoverFill.alphaComponent * hoverT)
            }
            fill.setFill()
            path.fill()
            (selected || isDrop ? Theme.itemSelectedOutline : Theme.itemHoverOutline).setStroke()
            path.stroke()
            // Several selected: the keyboard's current one keeps its focus frame, so arrow keys stay traceable.
            if selected, model.selection.count > 1, model.currentURL == url, window?.firstResponder === self {
                let inner = NSBezierPath(roundedRect: highlightRect(i).insetBy(dx: 2, dy: 2), xRadius: Theme.itemRadius, yRadius: Theme.itemRadius)
                inner.lineWidth = 1.5
                Theme.windowText.withAlphaComponent(0.7).setStroke()
                inner.stroke()
            }
        } else if model.selection.isEmpty && model.currentURL == url && window?.firstResponder === self {
            Theme.focus.withAlphaComponent(0.6).setStroke()
            path.stroke()
        }
    }

    /// Draws the preview, folder preview or icon; returns the image and where it went (for the cloud badge).
    private func drawIcon(_ i: Int) -> (NSImage, CGRect) {
        let item = model.rows[i].item
        let ir = iconRect(i)
        let alpha: CGFloat = (cutURLs.contains(item.url) || item.isHidden) ? 0.5 : 1
        if model.props.previews {
            if Thumbnails.wantsPreview(item), let thumb = Thumbnails.shared.thumbnail(for: item, size: iconSize) {
                let ts = thumb.size
                let scale = min(ir.width / max(ts.width, 1), ir.height / max(ts.height, 1))
                let w = ts.width * scale, h = ts.height * scale
                // Icons mode sits previews on the icon's baseline; list modes center them.
                let tr = CGRect(x: ir.midX - w / 2, y: mode == .icons ? ir.maxY - h : ir.midY - h / 2, width: w, height: h)
                NSGraphicsContext.saveGraphicsState()
                if iconSize >= 48 {
                    let sh = NSShadow(); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1)
                    sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.set()
                }
                thumb.draw(in: tr, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                return (thumb, tr)
            }
            if let fp = Thumbnails.shared.folderPreview(for: item, size: iconSize) {
                fp.draw(in: ir, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                return (fp, ir)
            }
        }
        let img = Icons.shared.image(for: item, size: iconSize)
        img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        return (img, ir)
    }

    /// Cloud state badge on the icon's lower right corner (white or blue, whichever reads on that icon).
    private func drawCloudBadge(_ cloud: CloudState, row i: Int, image: NSImage, imageRect: CGRect, selected: Bool) {
        guard cloud != .local else { cloudRects[i] = nil; return }
        // At least 14 pt, so it reads on small list icons too; it may overhang the icon's corner a little.
        let b = max(14, min(30, iconSize * 0.4))
        let over = b * 0.08
        let br = CGRect(x: imageRect.maxX + over - b, y: imageRect.maxY + over - b, width: b, height: b)
        let light = CloudBadge.backgroundIsLight(image, imageRect: imageRect, badge: br, behind: itemBackground(selected: selected))
        CloudBadge.draw(cloud, in: br, onLight: light)
        cloudRects[i] = br.insetBy(dx: -2, dy: -2)
        if cloud == .downloading || cloud == .uploading { scheduleCloudRefresh() }
    }

    private func drawLinkEmblem(_ i: Int, besideCloudBadge: Bool) {
        guard let emblem = Icons.shared.image("emblem-symbolic-link", size: iconSize >= 48 ? 16 : 10) else { return }
        let ir = iconRect(i)
        let es = emblem.size
        // Lower left when the cloud badge takes the lower right.
        let ex = besideCloudBadge ? ir.minX : ir.maxX - es.width
        emblem.draw(
            in: CGRect(x: ex, y: ir.maxY - es.height, width: es.width, height: es.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Roughly what is behind an item's badges and tag dots: the view color, tinted when selected.
    private func itemBackground(selected: Bool) -> NSColor {
        guard selected else { return Theme.viewBackground }
        return Theme.viewBackground.blended(withFraction: 0.32, of: Theme.selection) ?? Theme.viewBackground
    }

    private var tagDotDiameter: CGFloat { max(8, round(lineHeight * 0.62)) }

    private func roleTextColor(selected: Bool) -> NSColor {
        (selected ? Theme.selectionText : Theme.viewTextInactive).withAlphaComponent(0.85)
    }

    private func nameAttributes(_ item: FileItem) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: Theme.viewText.withAlphaComponent(item.isHidden ? 0.65 : 1), .paragraphStyle: nameParagraph]
    }

    private var nameParagraph: NSParagraphStyle {
        Settings.shared.elideMiddle ? Self.middleElidingParagraph : Self.tailElidingParagraph
    }

    private static let middleElidingParagraph = paragraph(.byTruncatingMiddle)
    private static let tailElidingParagraph = paragraph(.byTruncatingTail)
    private static let centeredRoleParagraph = paragraph(.byTruncatingMiddle, alignment: .center)
    private static let leftColumnParagraph = paragraph(.byTruncatingTail, alignment: .left)
    private static let rightColumnParagraph = paragraph(.byTruncatingTail, alignment: .right)

    private static func paragraph(_ lineBreak: NSLineBreakMode, alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = lineBreak
        p.alignment = alignment
        return p
    }

    /// Icons: the wrapped name (Finder's tag dots before a one-line name, under a wrapped one), then the roles.
    private func drawIconsText(_ i: Int, selected: Bool) {
        let item = model.rows[i].item
        let tr = nameTextRect(i)
        let (label, size) = iconsLabel(model.displayName(for: item), width: tr.width, maxLines: maxLabelLines)
        let m = NSMutableAttributedString(attributedString: label)
        m.addAttribute(
            .foregroundColor, value: Theme.viewText.withAlphaComponent(item.isHidden ? 0.65 : 1),
            range: NSRange(location: 0, length: m.length))
        let tags = model.shownTags(for: item)
        let d = tagDotDiameter
        let dotsW = FinderTags.dotsWidth(tags.count, diameter: d)
        let inlineDots = !tags.isEmpty && size.height <= lineHeight + 1 && size.width + dotsW + 4 <= tr.width
        var nameRect = CGRect(x: tr.minX, y: tr.minY, width: tr.width, height: size.height + 2)
        if inlineDots {
            let start = tr.midX - (size.width + dotsW + 4) / 2
            FinderTags.drawDots(
                tags, at: CGPoint(x: start, y: tr.minY + (lineHeight - d) / 2 + 1), diameter: d,
                background: itemBackground(selected: selected))
            nameRect.origin.x += (dotsW + 4) / 2
        }
        m.draw(with: nameRect, options: [.usesLineFragmentOrigin])
        var y = tr.minY + size.height
        if !tags.isEmpty && !inlineDots {
            FinderTags.drawDots(tags, at: CGPoint(x: tr.midX - dotsW / 2, y: y + 2), diameter: d, background: itemBackground(selected: selected))
            y += d + 4
        }
        let roleAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: Self.centeredRoleParagraph,
            .foregroundColor: roleTextColor(selected: selected),
        ]
        for role in model.props.roles(for: .icons) {
            (model.text(for: role, of: item) as NSString).draw(
                in: CGRect(x: tr.minX, y: y, width: tr.width, height: lineHeight),
                withAttributes: roleAttrs)
            y += lineHeight
        }
    }

    /// Compact: the name line, then one line per role, centered as a block next to the icon.
    private func drawCompactText(_ i: Int, selected: Bool) {
        let item = model.rows[i].item
        let tr = nameTextRect(i)
        let roles = model.props.roles(for: .compact)
        var y = tr.midY - lineHeight * CGFloat(1 + roles.count) / 2
        drawNameWithTags(item, in: CGRect(x: tr.minX, y: y, width: tr.width, height: lineHeight), selected: selected)
        y += lineHeight
        let roleAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: roleTextColor(selected: selected), .paragraphStyle: nameParagraph,
        ]
        for role in roles {
            (model.text(for: role, of: item) as NSString).draw(
                in: CGRect(x: tr.minX, y: y, width: tr.width, height: lineHeight),
                withAttributes: roleAttrs)
            y += lineHeight
        }
    }

    /// Details: the name (hidden while the rename field covers it), then one cell per column.
    private func drawDetailsText(_ i: Int, selected: Bool, showName: Bool) {
        let item = model.rows[i].item
        let tr = nameTextRect(i)
        let y = tr.midY - lineHeight / 2
        if showName {
            drawNameWithTags(item, in: CGRect(x: tr.minX, y: y, width: tr.width, height: lineHeight), selected: selected)
        }
        var x = frames[i].minX + (columnWidths[.name] ?? 0)
        for role in detailsRoles.dropFirst() {
            let w = columnWidths[role] ?? 100
            let p = role.rightAligned ? Self.rightColumnParagraph : Self.leftColumnParagraph
            (model.text(for: role, of: item) as NSString).draw(
                in: CGRect(x: x + 6, y: y, width: w - 14, height: lineHeight),
                withAttributes: [.font: font, .foregroundColor: Theme.viewText, .paragraphStyle: p])
            x += w
        }
    }

    /// One-line name followed by its Finder tag dots.
    private func drawNameWithTags(_ item: FileItem, in r: CGRect, selected: Bool) {
        let name = model.displayName(for: item)
        let tags = model.shownTags(for: item)
        let d = tagDotDiameter
        let dw = tags.isEmpty ? 0 : FinderTags.dotsWidth(tags.count, diameter: d) + 5
        let nameW = min(textWidth(name) + 1, max(0, r.width - dw - 2))
        (name as NSString).draw(in: CGRect(x: r.minX, y: r.minY, width: nameW, height: r.height), withAttributes: nameAttributes(item))
        if !tags.isEmpty {
            FinderTags.drawDots(
                tags, at: CGPoint(x: r.minX + nameW + 5, y: r.minY + (r.height - d) / 2 + 1), diameter: d,
                background: itemBackground(selected: selected))
        }
    }

    /// Breeze's emblem-added / emblem-remove as KDE renders them with the color scheme: a light disc with +/−.
    private func drawSelectionMarker(in r: CGRect, selected: Bool) {
        let disc = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        Theme.viewText.withAlphaComponent(hoverOnMarker ? 0.95 : 0.75).setFill()
        disc.fill()
        let m = r.width * 0.28
        let sym = NSBezierPath()
        sym.move(to: CGPoint(x: r.midX - m, y: r.midY))
        sym.line(to: CGPoint(x: r.midX + m, y: r.midY))
        if !selected {
            sym.move(to: CGPoint(x: r.midX, y: r.midY - m))
            sym.line(to: CGPoint(x: r.midX, y: r.midY + m))
        }
        sym.lineWidth = max(1.5, r.width / 9)
        sym.lineCapStyle = .round
        Theme.viewBackground.setStroke()
        sym.stroke()
    }

    /// Tree branch lines in Details (Dolphin 25.x): vertical lines for open levels, a tick to each item.
    private func drawTreeLines(_ i: Int) {
        let f = frames[i]
        let info = treeLines[i]
        let depth = model.rows[i].depth
        Theme.viewText.withAlphaComponent(0.28).setFill()
        for level in 0...depth {
            let x = floor(f.minX + CGFloat(level) * Self.indentPerLevel + 8)
            if level == depth {
                // └ or ├ for the item itself
                let bottom = info[level] ? f.maxY : f.midY
                CGRect(x: x, y: f.minY, width: 1, height: bottom - f.minY).fill()
                let tickStart = model.rows[i].item.isBrowsableFolder ? x + 8 : x
                let tickEnd = iconRect(i).minX - 4
                if tickEnd > tickStart { CGRect(x: tickStart, y: floor(f.midY), width: tickEnd - tickStart, height: 1).fill() }
            } else if info[level] {
                CGRect(x: x, y: f.minY, width: 1, height: f.height).fill()
            }
        }
        // Gap behind the expander arrow so the line doesn't cross it.
        if let er = expanderRect(i) {
            (i % 2 == 1 ? Theme.viewAlternate : Theme.viewBackground).setFill()
            CGRect(x: er.midX - 6, y: er.midY - 6, width: 12, height: 12).fill()
        }
    }

    /// Re-reads cloud states once a second while something is transferring.
    private func scheduleCloudRefresh() {
        guard !cloudRefreshPending else { return }
        cloudRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.cloudRefreshPending = false
            self.model.refreshCloud()
            self.needsDisplay = true
        }
    }
}
