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
        drawLeavingItems()
        for i in transitionIndexes(in: dirty.insetBy(dx: -40, dy: -4)) {
            drawItemInTransition(i, draw: drawItem)
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

    /// Row `i` drawn on its own into a picture of its cell (or of `part` of it), at the screen's scale. Drawn directly rather than
    /// cut from a `cacheDisplay` of the view: that runs the view's display machinery, and taken during an animation
    /// it left stale pieces of frames on screen.
    func picture(ofRow i: Int, part: CGRect? = nil) -> CGImage? {
        let r = part ?? frames[i]
        let scale = window?.backingScaleFactor ?? 2
        let w = Int((r.width * scale).rounded(.up)), h = Int((r.height * scale).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        // The view's flipped coordinates onto the bitmap: the cell's top-left at the image's top-left.
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -r.minX, y: -r.maxY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawItem(i)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

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
        let incoming = model.incomingProgress[item.url]
        let cloud = model.shownCloud(for: item).state
        NSGraphicsContext.saveGraphicsState()
        if incoming != nil || dimmedOffline(cloud) { NSGraphicsContext.current?.cgContext.setAlpha(0.5) }
        defer {
            NSGraphicsContext.restoreGraphicsState()
            if let incoming, mode != .details {
                let name = nameTextRect(i)
                drawIncomingBar(incoming, in: CGRect(x: name.minX, y: name.maxY + 2, width: min(48, name.width), height: 4))
            }
        }
        let (image, imageRect) = drawIcon(i)
        // The list modes draw the badge after the name (drawNameWithTags); Icons on the icon's corner.
        let badge = cloudBadge(item, state: cloud)
        cloudRects[i] = nil
        if mode == .icons { drawIconBadge(badge, row: i, imageRect: imageRect, selected: selected) }
        if item.isSymlink || item.isAliasFile || item.isWebDocument {
            drawLinkEmblem(i, besideCloudBadge: mode == .icons && badge != .none)
        }

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
                // Dimmed while the keys go elsewhere (another pane, window, panel or field), as Finder does.
                let focused = isActiveView && window?.isKeyWindow != false && window?.firstResponder === self
                let base = focused ? Theme.itemSelectedFill : Theme.itemSelectedFill.withAlphaComponent(0.6)
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
        let alpha: CGFloat = (cutURLs.contains(item.url) || item.isHidden || model.incomingProgress[item.url] != nil) ? 0.5 : 1
        if model.props.previews {
            if Thumbnails.wantsPreview(item), let thumb = Thumbnails.shared.thumbnail(for: item, size: iconSize, owner: self) {
                let ts = thumb.size
                // Large previews keep a gap above their label (they fill the cell, so they would touch it).
                let gap: CGFloat = mode == .icons && iconSize >= 64 ? 4 : 0
                let scale = min(ir.width / max(ts.width, 1), (ir.height - gap) / max(ts.height, 1))
                let w = ts.width * scale, h = ts.height * scale
                // Icons mode sits previews on the icon's baseline; list modes center them.
                let tr = CGRect(x: ir.midX - w / 2, y: mode == .icons ? ir.maxY - gap - h : ir.midY - h / 2, width: w, height: h)
                NSGraphicsContext.saveGraphicsState()
                if iconSize >= 48 {
                    let sh = NSShadow(); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1)
                    sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.set()
                }
                thumb.draw(in: tr, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                if gap > 0 {
                    // A hairline edge, as Finder draws: a pale photo doesn't melt into the view.
                    Theme.viewText.withAlphaComponent(0.12).setStroke()
                    let edge = NSBezierPath(rect: tr.insetBy(dx: 0.25, dy: 0.25))
                    edge.lineWidth = 0.5
                    edge.stroke()
                }
                return (thumb, tr)
            }
            if let fp = Thumbnails.shared.folderPreview(for: item, size: iconSize, owner: self) {
                fp.draw(in: ir, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                return (fp, ir)
            }
        }
        // Mid-zoom: one of the few step sizes, already rendered, as a bitmap scaled into the cell (see liveRenderSize).
        let img =
            liveIconSize.map { live in
                let step = Icons.shared.image(for: item, size: ZoomLevels.liveRenderSize(for: live))
                return Icons.shared.flattened(step, scale: window?.backingScaleFactor ?? 2)
            } ?? Icons.shared.image(for: item, size: iconSize)
        img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        return (img, ir)
    }

    /// Cloud state badge on the icon's lower right corner (white or blue, whichever reads on that icon).
    /// The item's one badge: an edit in progress, else its cloud state.
    func cloudBadge(_ item: FileItem, state: CloudState? = nil) -> CloudBadgeKind {
        CloudBadgeKind.resolve(state ?? model.shownCloud(for: item).state, edit: editMark(item))
    }

    /// Icons: one disc on the icon's lower right corner, overhanging it a little so it covers less of the glyph.
    private func drawIconBadge(_ badge: CloudBadgeKind, row i: Int, imageRect: CGRect, selected: Bool) {
        guard let look = CloudBadge.look(badge) else { return }
        let b = max(16, min(30, iconSize * 0.34))
        let over = b * 0.22
        let br = CGRect(x: imageRect.maxX + over - b, y: imageRect.maxY + over - b, width: b, height: b)
        CloudBadge.drawBadge(look, in: br, disc: itemBackground(selected: selected))
        noteBadge(badge, rect: br, row: i)
    }

    /// List modes: the glyph after the name and tags, at text size; returns where it ends.
    private func drawStatusGlyph(_ badge: CloudBadgeKind, row i: Int, at x: CGFloat, in line: CGRect, selected: Bool) -> CGFloat {
        guard let look = CloudBadge.look(badge, selected: selected) else { return x }
        let g = statusGlyphSize
        let r = CGRect(x: x + 5, y: line.midY - g / 2, width: g, height: g)
        CloudBadge.drawGlyph(look, in: r)
        noteBadge(badge, rect: r, row: i)
        return r.maxX
    }

    /// 14–16 pt, following the text.
    var statusGlyphSize: CGFloat { min(16, max(14, round(lineHeight * 0.8))) }

    /// Where the badge can be clicked and hovered; iCloud transfers are read again while they last (accounts' come
    /// from the offline service's notifications).
    private func noteBadge(_ badge: CloudBadgeKind, rect: CGRect, row i: Int) {
        cloudRects[i] = rect.insetBy(dx: -2, dy: -2)
        if badge.cloudState?.isTransferring == true, model.rows[i].item.url.isFileURL { scheduleCloudRefresh() }
    }

    /// Offline, files that are only in the cloud are drawn faded: what's on this Mac still opens.
    func dimmedOffline(_ cloud: CloudState) -> Bool {
        guard cloud == .cloudOnly, !model.location.isFileURL else { return false }
        return CloudAccounts.shared.account(for: model.location)?.status == .offline
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
        drawNameWithTags(item, row: i, in: CGRect(x: tr.minX, y: y, width: tr.width, height: lineHeight), selected: selected)
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
            let end = drawNameWithTags(item, row: i, in: CGRect(x: tr.minX, y: y, width: tr.width, height: lineHeight), selected: selected)
            if let line = model.searchSnippet(for: item) {
                drawSnippet(line, in: CGRect(x: end + 10, y: y, width: tr.maxX - end - 10, height: lineHeight), selected: selected)
            } else if let edit = editMark(item) {
                drawEditNote(edit, of: item.url, in: CGRect(x: end + 10, y: y, width: tr.maxX - end - 10, height: lineHeight), selected: selected)
            }

        }
        var x = frames[i].minX + (columnWidths[.name] ?? 0)
        for role in detailsRoles.dropFirst() {
            let w = columnWidths[role] ?? 100
            // A path is told apart by its end: elide its middle.
            let p = role.rightAligned ? Self.rightColumnParagraph : role == .path ? Self.middleElidingParagraph : Self.leftColumnParagraph
            if role == .size, let incoming = model.incomingProgress[item.url] {
                drawIncomingBar(incoming, in: CGRect(x: x + 6, y: y + lineHeight / 2 - 1.5, width: min(48, max(12, w - 50)), height: 4))
                ("\(Int(incoming * 100))%" as NSString).draw(
                    in: CGRect(x: x + min(72, max(24, w - 38)), y: y, width: 38, height: lineHeight),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Theme.viewTextInactive])
                x += w; continue
            }
            (model.text(for: role, of: item) as NSString).draw(
                in: CGRect(x: x + 6, y: y, width: w - 14, height: lineHeight),
                withAttributes: [.font: font, .foregroundColor: Theme.viewText, .paragraphStyle: p])
            x += w
        }
    }

    private func drawIncomingBar(_ fraction: Double, in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(1)
        defer { NSGraphicsContext.restoreGraphicsState() }
        Theme.viewText.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        Theme.activeText.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width * max(0, min(1, fraction)), height: rect.height), xRadius: 1.5,
            yRadius: 1.5
        ).fill()
    }

    /// A cloud file open in another app: how its saves are doing.
    func editMark(_ item: FileItem) -> CloudEditMark? {
        CloudEditing.shared.mark(for: item.url)
    }

    /// After the name in Details: "Editing · changes save to Dropbox", quiet unless it needs attention.
    private func drawEditNote(_ mark: CloudEditMark, of url: URL, in r: CGRect, selected: Bool) {
        guard r.width > 60 else { return }
        let color = selected ? Theme.selectionText : mark.needsAttention ? Theme.transferDanger : roleTextColor(selected: selected)
        (mark.note(CloudAccounts.shared.providerTitle(for: url)) as NSString).draw(
            in: r,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: max(10, font.pointSize - 1)), .foregroundColor: color, .paragraphStyle: Self.tailElidingParagraph,
            ])
    }

    /// A content match's line after its name: dimmed, the text searched for in full color.
    private func drawSnippet(_ line: String, in r: CGRect, selected: Bool) {
        guard r.width > 40, let text = model.searchMatches?.text else { return }
        let s = NSMutableAttributedString(
            string: line, attributes: [.font: font, .foregroundColor: roleTextColor(selected: selected), .paragraphStyle: Self.tailElidingParagraph])
        var from = line.startIndex
        while let m = line.range(of: text, options: [.caseInsensitive, .diacriticInsensitive], range: from..<line.endIndex) {
            s.addAttributes(
                [
                    .foregroundColor: selected ? Theme.selectionText : Theme.viewText,
                    .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                ], range: NSRange(m, in: line))
            from = m.upperBound
        }
        s.draw(in: r)
    }

    /// One-line name followed by its Finder tag dots and its cloud glyph (row `i`); returns where they end.
    @discardableResult
    private func drawNameWithTags(_ item: FileItem, row i: Int, in r: CGRect, selected: Bool) -> CGFloat {
        let name = model.displayName(for: item)
        let tags = model.shownTags(for: item)
        let d = tagDotDiameter
        let dw = tags.isEmpty ? 0 : FinderTags.dotsWidth(tags.count, diameter: d) + 5
        let badge = cloudBadge(item)
        // A long name gives way to the glyph, which always shows.
        let gw = badge == .none ? 0 : statusGlyphSize + 5
        let nameW = min(textWidth(name) + 1, max(0, r.width - dw - gw - 2))
        (name as NSString).draw(in: CGRect(x: r.minX, y: r.minY, width: nameW, height: r.height), withAttributes: nameAttributes(item))
        if !tags.isEmpty {
            FinderTags.drawDots(
                tags, at: CGPoint(x: r.minX + nameW + 5, y: r.minY + (r.height - d) / 2 + 1), diameter: d,
                background: itemBackground(selected: selected))
        }
        return drawStatusGlyph(badge, row: i, at: r.minX + nameW + dw, in: r, selected: selected)
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
        guard depth > 0 else { return }
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
