import AppKit
import PorpoiseCore

/// The type scale, shortened for the text styles in this file.
private typealias FontSize = Tokens.FontSize

struct FileDiffRow {
    var left: Int?
    var right: Int?
    var change: Int?
    var leftWords: [NSRange] = []
    var rightWords: [NSRange] = []
}

struct FileDiffPresentation {
    let difference: TextDifference
    let rows: [FileDiffRow]
    let starts: [Int]
    init(_ d: TextDifference, inline: Bool) {
        self.init(d, inline: inline, checkCancellation: {})
    }
    init(_ d: TextDifference, inline: Bool, checkCancellation: () throws -> Void) rethrows {
        try checkCancellation()
        difference = d
        var rows: [FileDiffRow] = [], starts: [Int] = [], l = 0, r = 0
        for (index, c) in d.changes.enumerated() {
            try checkCancellation()
            while l < c.left.lowerBound && r < c.right.lowerBound {
                if l % 256 == 0 { try checkCancellation() }; rows.append(FileDiffRow(left: l, right: r)); l += 1; r += 1
            }
            starts.append(rows.count)
            if inline {
                for i in c.left {
                    try checkCancellation()
                    let j = c.right.lowerBound + i - c.left.lowerBound
                    let spans =
                        j < c.right.upperBound ? try WordDifference.ranges(d.left[i], d.right[j], checkCancellation: checkCancellation).left : []
                    rows.append(FileDiffRow(left: i, change: index, leftWords: spans))
                }
                for j in c.right {
                    try checkCancellation()
                    let i = c.left.lowerBound + j - c.right.lowerBound
                    let spans =
                        i < c.left.upperBound ? try WordDifference.ranges(d.left[i], d.right[j], checkCancellation: checkCancellation).right : []
                    rows.append(FileDiffRow(right: j, change: index, rightWords: spans))
                }
            } else {
                for k in 0..<max(c.left.count, c.right.count) {
                    try checkCancellation()
                    let x = c.left.lowerBound + k, y = c.right.lowerBound + k
                    var row = FileDiffRow(left: x < c.left.upperBound ? x : nil, right: y < c.right.upperBound ? y : nil, change: index)
                    if let x = row.left, let y = row.right {
                        let spans = try WordDifference.ranges(d.left[x], d.right[y], checkCancellation: checkCancellation);
                        row.leftWords = spans.left; row.rightWords = spans.right
                    }
                    rows.append(row)
                }
            }
            l = c.left.upperBound; r = c.right.upperBound
        }
        while l < d.left.count || r < d.right.count {
            if l % 256 == 0 { try checkCancellation() }
            rows.append(FileDiffRow(left: l < d.left.count ? l : nil, right: r < d.right.count ? r : nil)); l += 1; r += 1
        }
        self.rows = rows; self.starts = starts
    }
}

/// One clip offset drives both panes and the seam; only visible lines are shaped and drawn.
final class FileDiffTextView: NSView {
    var presentation: FileDiffPresentation?
    var canCopyChanges = true
    var forceContrast = false
    var inline = false
    var focused = 0
    var copyChange: ((Int, Bool) -> Void)?
    var jump: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    private var hover: Int?
    private let copyLeft = ClosureButton(title: "←") { _ in }
    private let copyRight = ClosureButton(title: "→") { _ in }
    private var buttonChange = 0
    private var horizontalOffset: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            horizontalOffset = max(0, horizontalOffset + (event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX));
            needsDisplay = true
        } else {
            super.scrollWheel(with: event)
        }
    }
    func updateCopyButtons() {
        guard let p = presentation else { copyLeft.isHidden = true; copyRight.isHidden = true; return }
        let c = hover ?? focused
        guard canCopyChanges, !inline, p.starts.indices.contains(c) else { copyLeft.isHidden = true; copyRight.isHidden = true; return }
        let change = p.difference.changes[c], height = CGFloat(max(change.left.count, change.right.count)) * 18
        let y = 10 + CGFloat(p.starts[c]) * 18 + height / 2 - 9
        buttonChange = c
        for (button, dx) in [(copyLeft, -10.0), (copyRight, 10.0)] {
            button.isHidden = false; button.frame = NSRect(x: (bounds.width - 8) / 2 + dx - 9, y: y, width: 18, height: 18)
        }
    }
    let lineHeight: CGFloat = 18
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [copyLeft, copyRight] {
            b.bezelStyle = .circular; b.controlSize = .small; b.font = .systemFont(ofSize: FontSize.small, weight: .semibold)
            b.wantsLayer = true; b.layer?.shadowColor = NSColor.black.cgColor; b.layer?.shadowOpacity = 0.12; b.layer?.shadowRadius = 2;
            b.layer?.shadowOffset = NSSize(width: 0, height: -1)
            b.isHidden = true; addSubview(b)
        }
        copyLeft.setAccessibilityLabel("Copy Change to Left"); copyRight.setAccessibilityLabel("Copy Change to Right")
        copyLeft.handler = { [weak self] _ in
            guard let self else { return }; self.copyChange?(self.buttonChange, false)
        }
        copyRight.handler = { [weak self] _ in
            guard let self else { return }; self.copyChange?(self.buttonChange, true)
        }
        setAccessibilityElement(true); setAccessibilityRole(.textArea);
        setAccessibilityLabel("File comparison. Use Previous and Next Change to navigate differences.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func row(at point: NSPoint) -> Int { max(0, Int((point.y - 10) / lineHeight)) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), i = row(at: p)
        hover = presentation?.rows.indices.contains(i) == true ? presentation?.rows[i].change : nil; updateCopyButtons(); needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hover = nil; updateCopyButtons(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard let p = presentation else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.x > bounds.width - 8 {
            let target = Int(((point.y - visibleRect.minY) / max(1, visibleRect.height) * bounds.height - 10) / lineHeight)
            if let best = p.starts.indices.min(by: { abs(p.starts[$0] - target) < abs(p.starts[$1] - target) }) { jump?(best) }; return
        }
        if canCopyChanges, !inline, abs(point.x - (bounds.width - 8) / 2) < 20 {
            let i = row(at: point)
            if p.rows.indices.contains(i), let c = p.rows[i].change { copyChange?(c, point.x > (bounds.width - 8) / 2) }
        } else {
            window?.makeFirstResponder(self)
        }
    }
    private func color(_ row: FileDiffRow) -> NSColor {
        row.left == nil ? Theme.transferPositive : (row.right == nil ? Theme.transferDanger : Theme.transferChanged)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.viewBackground.setFill(); dirtyRect.fill()
        guard let p = presentation else { return }
        let width = bounds.width - 8, half = width / 2, seam: CGFloat = inline ? 0 : 40
        if !inline { Theme.windowBackground.setFill(); NSRect(x: half - 20, y: dirtyRect.minY, width: 40, height: dirtyRect.height).fill() }
        let start = max(0, Int((dirtyRect.minY - 10) / lineHeight)), end = min(p.rows.count, Int(dirtyRect.maxY / lineHeight) + 1)
        guard start < end else { return }
        for index in start..<end {
            let row = p.rows[index], y = 10 + CGFloat(index) * lineHeight
            if row.change != nil {
                color(row).withAlphaComponent((Theme.increasedContrast || forceContrast) ? 0.18 : 0.10).setFill()
                if inline || row.left != nil { NSRect(x: 0, y: y, width: inline ? width : half - 20, height: 18).fill() }
                if !inline && row.right != nil { NSRect(x: half + 20, y: y, width: half - 20, height: 18).fill() }
                if Theme.increasedContrast || forceContrast {
                    color(row).setFill(); NSRect(x: inline ? 0 : half - 22, y: y, width: 2, height: 18).fill()
                }
            }
            if inline {
                let text = row.left.map { p.difference.left[$0] } ?? row.right.map { p.difference.right[$0] } ?? ""
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: FontSize.small, weight: .regular),
                    .foregroundColor: row.change == focused ? Theme.accent : Theme.viewTextInactive.withAlphaComponent(0.7),
                    .paragraphStyle: Self.rightAligned,
                ]
                if let l = row.left { ("\(l + 1)" as NSString).draw(in: NSRect(x: 2, y: y + 1, width: 30, height: 17), withAttributes: attrs) }
                if let r = row.right { ("\(r + 1)" as NSString).draw(in: NSRect(x: 34, y: y + 1, width: 30, height: 17), withAttributes: attrs) }
                drawLine(
                    text, number: nil, x: 30, y: y, width: width - 30, ranges: row.left == nil ? row.rightWords : row.leftWords, tint: color(row),
                    mark: row.change == nil ? "" : (row.left == nil ? "+" : "−"), focused: row.change == focused)
            } else {
                if let i = row.left {
                    drawLine(
                        p.difference.left[i], number: i + 1, x: 0, y: y, width: half - seam / 2, ranges: row.leftWords, tint: color(row),
                        focused: row.change == focused)
                }
                if let i = row.right {
                    drawLine(
                        p.difference.right[i], number: i + 1, x: half + 20, y: y, width: half - 20, ranges: row.rightWords, tint: color(row),
                        focused: row.change == focused)
                }
            }
        }
        if !inline {
            var low = 0, high = p.starts.count
            while low < high { let m = (low + high) / 2; if p.starts[m] < start { low = m + 1 } else { high = m } }
            for c in max(0, low - 1)..<p.starts.count {
                let first = p.starts[c]
                if first > end { break }
                let block = p.difference.changes[c], count = max(block.left.count, block.right.count)
                let y = 10 + CGFloat(first) * 18, h = CGFloat(max(1, count)) * 18
                guard NSRect(x: half - 20, y: y, width: 40, height: h).intersects(dirtyRect) else { continue }
                let tint = color(p.rows[first]), path = NSBezierPath()
                let leftH: CGFloat = block.left.isEmpty ? 1 : h, rightH: CGFloat = block.right.isEmpty ? 1 : h
                path.move(to: NSPoint(x: half - 20, y: y));
                path.curve(to: NSPoint(x: half + 20, y: y), controlPoint1: NSPoint(x: half, y: y), controlPoint2: NSPoint(x: half, y: y))
                path.line(to: NSPoint(x: half + 20, y: y + rightH));
                path.curve(
                    to: NSPoint(x: half - 20, y: y + leftH), controlPoint1: NSPoint(x: half, y: y + rightH),
                    controlPoint2: NSPoint(x: half, y: y + leftH));
                path.close()
                Theme.viewBackground.setFill(); path.fill(); tint.withAlphaComponent(0.14).setFill(); path.fill();
                tint.withAlphaComponent(0.4).setStroke(); path.stroke()

            }
        }
        Theme.windowBackground.setFill(); NSRect(x: width, y: visibleRect.minY, width: 8, height: visibleRect.height).fill()
        for i in stride(from: 0, to: p.starts.count, by: max(1, p.starts.count / max(1, Int(visibleRect.height)))) {
            let start = p.starts[i]
            let y = visibleRect.minY + (10 + CGFloat(start) * lineHeight) / max(1, bounds.height) * visibleRect.height
            color(p.rows[start]).setFill(); NSRect(x: width + 1, y: y, width: 6, height: i == focused ? 4 : 2).fill()
        }
    }
    private func drawLine(
        _ line: String, number: Int?, x: CGFloat, y: CGFloat, width: CGFloat, ranges: [NSRange], tint: NSColor, mark: String = "",
        focused: Bool = false
    ) {
        NSGraphicsContext.saveGraphicsState(); NSRect(x: x, y: y, width: max(0, width - 12), height: 18).clip()
        if let number {
            let num = "\(number)" as NSString
            num.draw(
                in: NSRect(x: x + 3, y: y + 1, width: 34, height: 17),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: FontSize.small, weight: .regular),
                    .foregroundColor: focused ? Theme.accent : Theme.viewTextInactive.withAlphaComponent(0.7), .paragraphStyle: Self.rightAligned,
                ])
        }
        if !mark.isEmpty {
            (mark as NSString).draw(
                at: NSPoint(x: x + 39, y: y),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: FontSize.callout, weight: .bold), .foregroundColor: tint])
        }
        // Never shape an unbounded single line on the UI thread. The full bytes remain in the model for copying/saving.
        let text = String(line.prefix(2048)).trimmingCharacters(in: .newlines) as NSString
        let font = NSFont.monospacedSystemFont(ofSize: FontSize.callout, weight: .regular), origin = NSPoint(x: x + 48 - horizontalOffset, y: y + 1)
        for range in ranges where range.location < text.length {
            let end = min(text.length, NSMaxRange(range)), before = text.substring(to: range.location) as NSString,
                word = text.substring(with: NSRange(location: range.location, length: end - range.location)) as NSString
            let a = (before.replacingOccurrences(of: "\t", with: "    ") as NSString).size(withAttributes: [.font: font]).width,
                w = (word.replacingOccurrences(of: "\t", with: "    ") as NSString).size(withAttributes: [.font: font]).width
            tint.withAlphaComponent(Self.wordTintAlpha(dark: effectiveAppearance.isDark)).setFill();
            NSBezierPath(roundedRect: NSRect(x: origin.x + a, y: y + 1, width: w, height: 16), xRadius: 3, yRadius: 3).fill()
        }
        (text.replacingOccurrences(of: "\t", with: "    ") as NSString).draw(
            at: origin, withAttributes: [.font: font, .foregroundColor: Theme.viewText])
        NSGraphicsContext.restoreGraphicsState()
    }
    /// The changed words' tint over their line's 10 % tint: 0.26 measured 1.31:1 against the line in light (too faint
    /// to find the edit) and 1.84:1 in dark; light gets 0.40 (1.54:1 measured). Text keeps 4.5:1 or more on both.
    static func wordTintAlpha(dark: Bool) -> CGFloat { dark ? 0.26 : 0.40 }

    private static let rightAligned: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.alignment = .right; return p
    }()
}
