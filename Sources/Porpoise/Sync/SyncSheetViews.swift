import AppKit
import PorpoiseCore
import PorpoiseServices
import UniformTypeIdentifiers

final class SyncSheetBackdrop: NSView {
    var onLayout: (() -> Void)?
    var footerY: CGFloat = 0
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill(); bounds.fill()
        Theme.frame.setFill(); CGRect(x: 0, y: footerY, width: bounds.width, height: 1).fill()
    }
}
final class SyncListBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Theme.viewBackground.setFill(); path.fill(); Theme.frame.setStroke(); path.lineWidth = 1; path.stroke()
    }
}
final class SyncCalloutView: NSView {
    var text = "" { didSet { setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text) } }
    var danger = false
    var warning = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let color = warning ? Theme.compareChanged : danger ? Theme.compareDanger : Theme.activeText
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        color.withAlphaComponent(Theme.increasedContrast ? 0.18 : 0.08).setFill(); path.fill()
        color.withAlphaComponent(0.4).setStroke(); path.lineWidth = 1; path.stroke()
        let content = (text.hasPrefix("⚠ ") || text.hasPrefix("ⓘ ")) ? String(text.dropFirst(2)) : text
        let attributed = NSMutableAttributedString(
            string: content, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowText])
        if let sentence = content.range(of: ". ") {
            attributed.addAttribute(
                .font, value: NSFont.systemFont(ofSize: 11, weight: .semibold), range: NSRange(content.startIndex..<sentence.upperBound, in: content))
        }
        if let image = NSImage(systemSymbolName: danger || warning ? "exclamationmark.triangle.fill" : "info.circle", accessibilityDescription: nil) {
            image.isTemplate = true
            let icon = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
            icon.lockFocus(); image.draw(in: CGRect(x: 0, y: 0, width: 16, height: 16), from: .zero, operation: .destinationIn, fraction: 1);
            icon.unlockFocus()
            icon.draw(in: CGRect(x: 10, y: 8, width: 16, height: 16))
        }
        attributed.draw(in: CGRect(x: 34, y: 7, width: bounds.width - 44, height: bounds.height - 12))
    }
}
final class SyncClosureButton: ConflictActionButton {
    var perform: (() -> Void)?
    init(title: String) {
        super.init(frame: .zero); self.title = title; target = self; action = #selector(invoke); font = .systemFont(ofSize: 13);
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard drawsBackground else { super.draw(dirtyRect); return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        (primary ? Theme.activeText : Theme.viewBackground).withAlphaComponent(isEnabled ? (isHighlighted ? 0.7 : 1) : 0.4).setFill(); path.fill()
        (primary ? Theme.activeText : Theme.frame).withAlphaComponent(isEnabled ? 1 : 0.4).setStroke(); path.lineWidth = 1; path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: (titleTint ?? (primary ? (Theme.increasedContrast ? Self.primaryTextColor : .white) : Theme.windowText))
                .withAlphaComponent(isEnabled ? 1 : 0.7),
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }
    @objc private func invoke() { perform?() }
}
final class SyncModeCard: NSButton {
    let mode: SyncMode
    var chosen = false
    var leftName = "", rightName = ""
    var trashLocation = "the Trash"
    var perform: (() -> Void)?
    var moveSelection: ((Int) -> Void)?
    init(mode: SyncMode) {
        self.mode = mode; super.init(frame: .zero)
        title = mode == .twoWay ? "Two-way" : mode.rawValue.capitalized
        target = self; action = #selector(invoke)
        setAccessibilityRole(.radioButton); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform?() }
    override var isFlipped: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 { moveSelection?(event.keyCode == 123 ? -1 : 1) } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (chosen ? Theme.activeText.withAlphaComponent(0.08) : Theme.viewBackground).setFill(); path.fill()
        (chosen ? Theme.activeText : Theme.frame).setStroke(); path.lineWidth = chosen ? 2 : 1; path.stroke()
        let color = Theme.windowText
        color.withAlphaComponent(0.6).setStroke()
        for x: CGFloat in [12, 44] { NSBezierPath(roundedRect: CGRect(x: x, y: 10, width: 14, height: 12), xRadius: 2, yRadius: 2).stroke() }
        let arrows = NSBezierPath(); arrows.lineWidth = 1.5
        if mode == .twoWay {
            arrows.move(to: CGPoint(x: 28, y: 13)); arrows.line(to: CGPoint(x: 41, y: 13)); arrows.line(to: CGPoint(x: 37, y: 9))
            arrows.move(to: CGPoint(x: 41, y: 19)); arrows.line(to: CGPoint(x: 28, y: 19)); arrows.line(to: CGPoint(x: 32, y: 23))
        } else if mode == .mirror {
            arrows.move(to: CGPoint(x: 28, y: 13)); arrows.line(to: CGPoint(x: 38, y: 13))
            arrows.move(to: CGPoint(x: 28, y: 19)); arrows.line(to: CGPoint(x: 38, y: 19))
            arrows.move(to: CGPoint(x: 36, y: 10)); arrows.line(to: CGPoint(x: 42, y: 16)); arrows.line(to: CGPoint(x: 36, y: 22))
        } else {
            arrows.move(to: CGPoint(x: 28, y: 16)); arrows.line(to: CGPoint(x: 41, y: 16))
            arrows.move(to: CGPoint(x: 36, y: 11)); arrows.line(to: CGPoint(x: 41, y: 16)); arrows.line(to: CGPoint(x: 36, y: 21))
        }
        arrows.stroke()
        let hint = mode == .backup ? "⌘1" : mode == .mirror ? "⌘2" : "⌘3"
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        (hint as NSString).draw(
            at: CGPoint(x: 20 + titleWidth, y: 30),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowTextInactive])
        if chosen {
            Theme.activeText.setFill(); NSBezierPath(ovalIn: CGRect(x: bounds.width - 26, y: 10, width: 16, height: 16)).fill()
            ("✓" as NSString).draw(
                at: CGPoint(x: bounds.width - 23, y: 10),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: ConflictActionButton.primaryTextColor])
        }
        (title as NSString).draw(
            at: CGPoint(x: 12, y: 28), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color])
        let detail =
            mode == .backup
            ? "Copy new and changed files to \(rightName). Never deletes."
            : mode == .mirror
                ? "Make \(rightName) match \(leftName). Extra items go to \(trashLocation)." : "Bring both sides up to date. Asks when both changed."
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        (detail as NSString).draw(
            in: CGRect(x: 12, y: 47, width: bounds.width - 24, height: 30),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowTextInactive, .paragraphStyle: paragraph])
        setAccessibilityValue(chosen ? 1 : 0)
    }
}

final class SyncPlanRow: NSView {
    let step: SyncStep
    let pair: SavedSync
    var onInclude: ((Bool) -> Void)?
    var onChoice: ((SyncOverride) -> Void)?
    var onExclude: (() -> Void)?
    private var choiceValues: [SyncOverride] = []
    private var difference: SyncDifference?
    private let compareButton = SyncClosureButton(title: "Compare")
    private let include = SyncIncludeCheckbox(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let path = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private var choices: NSSegmentedControl?
    init(
        step: SyncStep, pair: SavedSync, checked: Bool, choice: SyncOverride?, difference: SyncDifference? = nil, hasState: Bool = false,
        unavailable: Bool = false,
        displayPath: String? = nil, isFolder: Bool = false, folderCount: Int? = nil, displayBytes: Int64? = nil
    ) {
        self.step = step; self.pair = pair; self.difference = difference; super.init(frame: .zero)
        if unavailable { include.isEnabled = false; include.toolTip = "This destination cannot keep deleted items. The item will be left in place." }
        include.contentTintColor = Theme.activeText
        include.state = checked && !unavailable ? .on : .off; include.target = self; include.action = #selector(toggled)
        include.setAccessibilityLabel("Include \(step.path)")
        if step.sourcePath != nil, step.path != difference?.left?.path, step.path != difference?.right?.path {
            include.isEnabled = false; include.toolTip = "Both versions are kept together. Change the original item’s choice to skip this group."
        }
        let folder = isFolder || (step.expectedSource ?? step.expectedTarget)?.kind == .directory
        let file = FileItem(
            url: pair.left.appendingPathComponent(step.path), name: (step.path as NSString).lastPathComponent, isDirectory: folder,
            contentType: UTType(filenameExtension: (step.path as NSString).pathExtension)?.identifier)
        icon.image = Icons.shared.image(Icons.shared.iconName(for: file), size: 16, folder: folder)
        path.stringValue = displayPath ?? (step.path.isEmpty ? "Both folders" : step.path)
        if let rename = step.renameTo {
            path.stringValue = "Rename \((step.path as NSString).lastPathComponent) to \((rename as NSString).lastPathComponent)"
            path.toolTip = path.stringValue + " in " + (step.target == .left ? pair.leftTitle : pair.rightTitle)
        }
        path.font = .systemFont(ofSize: 13); path.lineBreakMode = .byTruncatingMiddle;
        path.textColor = unavailable ? Theme.windowTextInactive : step.action == .trash ? Theme.compareDanger : Theme.windowText
        size.stringValue = FileFormat.size(displayBytes ?? step.expectedSource?.size ?? step.expectedTarget?.size ?? 0)
        size.font = .systemFont(ofSize: 11); size.textColor = Theme.windowTextInactive; size.alignment = .right
        detail.stringValue =
            step.reason
            ?? (step.action == .copy
                ? "new"
                : step.action == .mkdir
                    ? "new folder" : step.action == .trash ? "only in \(step.target == .left ? pair.leftTitle : pair.rightTitle)" : "changed")
        if step.renameTo == nil, step.action != .conflict, let difference, case .changed(let change) = difference.status {
            detail.stringValue =
                change == .newerLeft ? "newer in " + pair.leftTitle : change == .newerRight ? "newer in " + pair.rightTitle : "changed"
        }
        if let folderCount { size.stringValue = "\(folderCount) \(folderCount == 1 ? "item" : "items")" }
        detail.font = .systemFont(ofSize: 11)
        detail.textColor =
            step.action == .replace && pair.mode != .twoWay && difference?.status == .changed(.newerRight)
            ? Theme.compareDanger : Theme.windowTextInactive;
        detail.lineBreakMode = .byTruncatingTail
        [include, icon, path, detail, size].forEach(addSubview)
        if (!checked || unavailable) && step.action != .conflict { [icon, path, detail, size].forEach { $0.alphaValue = 0.5 } }
        if step.action == .conflict {
            let labels: [String]
            if let difference {
                func metadata(_ entry: SyncEntry?, _ title: String) -> String {
                    guard let entry else { return "Deleted in " + title }
                    let date =
                        entry.modified.map { date -> String in
                            let format = DateFormatter()
                            format.locale = .current
                            format.dateFormat = Calendar.current.isDateInToday(date) ? "'today' HH:mm" : "d MMM HH:mm"
                            return ", " + format.string(from: date)
                        } ?? ""
                    return title + " " + FileFormat.size(entry.size) + date
                }
                detail.stringValue =
                    (difference.left != nil && difference.right != nil ? (hasState ? "Changed on both sides · " : "Different on both sides · ") : "")
                    + metadata(difference.left, pair.leftTitle)
                    + " · " + metadata(difference.right, pair.rightTitle)
                detail.toolTip = (step.reason ?? "Changed on both sides") + " · " + detail.stringValue
            }
            if let difference, let left = difference.left, let right = difference.right,
                left.kind == right.kind, (left.path as NSString).lastPathComponent != (right.path as NSString).lastPathComponent,
                difference.status != .collision
            {
                labels = [(left.path as NSString).lastPathComponent, (right.path as NSString).lastPathComponent]
                choiceValues = [.keepLeft, .keepRight]
            } else if let difference, difference.left?.kind != .directory, difference.right?.kind != .directory,
                difference.left != nil, difference.right != nil, difference.left?.kind == difference.right?.kind, difference.status != .collision
            {
                labels = [pair.leftTitle, pair.rightTitle, "Both"]; choiceValues = [.keepLeft, .keepRight, .keepBoth]
            } else if let difference, hasState, (difference.left == nil) != (difference.right == nil),
                (difference.left ?? difference.right)?.kind != .directory
            {
                labels = ["Keep", "Move to Trash"]
                choiceValues = [difference.left == nil ? .keepRight : .keepLeft, .trash]
            } else {
                labels = ["Skip"]; choiceValues = [.skip]
            }
            let choices = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: #selector(chosen(_:)))
            choices.font = .systemFont(ofSize: 11); choices.controlSize = .small; choices.selectedSegment = -1
            if let choice, let index = choiceValues.firstIndex(of: choice) {
                choices.selectedSegment = index; choices.font = .systemFont(ofSize: 11, weight: .semibold)
            }
            choices.setAccessibilityLabel("Choose version for \(step.path)")
            self.choices = choices; addSubview(choices)
            if difference?.left?.kind == .file && difference?.right?.kind == .file {
                compareButton.perform = { [weak self] in self?.compare() }; addSubview(compareButton)
            }
        }

        setAccessibilityElement(true); setAccessibilityRole(.row)
        setAccessibilityLabel("\(step.path), \(detail.stringValue)" + (step.action == .conflict ? "" : ", " + size.stringValue))
        if step.action == .conflict { compareButton.setAccessibilityLabel("Compare " + step.path) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let width = max(200, bounds.width - 32)
        let conflict = step.action == .conflict
        include.frame = CGRect(x: 0, y: 2, width: 18, height: 20); include.isHidden = conflict
        icon.frame = CGRect(x: conflict ? 0 : 22, y: 4, width: 16, height: 16)
        path.frame = CGRect(x: 46, y: 3, width: max(80, width - (conflict ? 290 : 270)), height: 18)
        if conflict {
            detail.frame = CGRect(x: 46, y: 24, width: width - 54, height: 16)
            let hasCompare = compareButton.superview != nil
            let choiceWidth: CGFloat = choices?.segmentCount == 1 ? 64 : (hasCompare ? 208 : 232)
            choices?.frame = CGRect(x: max(130, width - choiceWidth - (hasCompare ? 80 : 8)), y: 1, width: choiceWidth, height: 22)
            compareButton.frame = CGRect(x: width - 74, y: 1, width: 70, height: 30)
            size.isHidden = true
        } else {
            size.frame = CGRect(x: width - 220, y: 4, width: 68, height: 16)
            detail.frame = CGRect(x: width - 142, y: 4, width: 134, height: 16)
        }
    }
    @objc private func toggled() { onInclude?(include.state == .on) }
    @objc private func chosen(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        onChoice?(choiceValues[sender.selectedSegment])
    }
}

extension SyncPlanRow {
    private func compare() {
        NotificationCenter.default.post(
            name: Notification.Name("PorpoiseCompareFilesRequested"), object: window,
            userInfo: [
                "left": pair.left.appendingPathComponent(difference?.left?.path ?? step.path),
                "right": pair.right.appendingPathComponent(difference?.right?.path ?? step.path),
            ])
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if difference?.left != nil {
            menu.addItem(
                SyncMenuItem(title: "Reveal in \(pair.leftTitle)") { [pair, step] in
                    AppDelegate.shared.newWindow(at: pair.left.appendingPathComponent(step.path).deletingLastPathComponent())
                })
        }
        if difference?.right != nil {
            menu.addItem(
                SyncMenuItem(title: "Reveal in \(pair.rightTitle)") { [pair, step] in
                    AppDelegate.shared.newWindow(at: pair.right.appendingPathComponent(step.path).deletingLastPathComponent())
                })
        }
        if difference?.left?.kind == .file && difference?.right?.kind == .file {
            menu.addItem(SyncMenuItem(title: "Compare Files") { [weak self] in self?.compare() })
        }
        menu.addItem(.separator())
        menu.addItem(SyncMenuItem(title: "Exclude from Future Syncs") { [weak self] in self?.onExclude?() })
        return menu
    }
}
final class SyncMenuItem: NSMenuItem {
    let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform() }
}

final class SyncDirectionView: NSView {
    var twoWay = false { didSet { updateAccessibility() } }
    var breadcrumb = ""
    var swappingTitles: [String]?
    var swapProgress: CGFloat = 0
    var source = "" { didSet { updateAccessibility() } }
    var destination = "" { didSet { updateAccessibility() } }
    private func updateAccessibility() {
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel(twoWay ? "\(source) and \(destination)" : "From \(source) to \(destination)")
    }
    override var isFlipped: Bool { true }
    private func chipWidth(_ title: String) -> CGFloat {
        min(160, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 40)
    }
    private var sourceWidth: CGFloat { chipWidth(swappingTitles?.first ?? source) }
    private var leading: CGFloat { twoWay ? 0 : 44 }
    var swapRect: CGRect { CGRect(x: leading + sourceWidth + 8, y: 0, width: 28, height: 28) }
    override func draw(_ dirtyRect: NSRect) {
        if !twoWay {
            ("From" as NSString).draw(
                at: CGPoint(x: 0, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.windowTextInactive])
        } else {
            ("⇄" as NSString).draw(
                at: CGPoint(x: swapRect.minX + 6, y: 3),
                withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: Theme.windowTextInactive])
        }
        let breadcrumbX = leading + 44 + sourceWidth + chipWidth(destination) + 12
        let breadcrumbStyle = NSMutableParagraphStyle(); breadcrumbStyle.lineBreakMode = .byTruncatingMiddle
        (breadcrumb as NSString).draw(
            in: CGRect(x: breadcrumbX, y: 6, width: max(0, bounds.width - breadcrumbX), height: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Theme.windowTextInactive, .paragraphStyle: breadcrumbStyle])
        for (index, title) in (swappingTitles ?? [source, destination]).enumerated() {
            let crossing = swappingTitles != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let position = CGFloat(index) + (crossing ? (index == 0 ? swapProgress : -swapProgress) : 0)
            let box = CGRect(x: leading + position * (sourceWidth + 44), y: 0, width: chipWidth(title), height: 28)
            let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            Theme.viewBackground.setFill(); shape.fill(); Theme.frame.setStroke(); shape.lineWidth = 1; shape.stroke()
            Icons.shared.image("folder", size: 16)?.draw(
                in: CGRect(x: box.minX + 8, y: 6, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                hints: nil)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
            (title as NSString).draw(
                in: CGRect(x: box.minX + 32, y: 5, width: box.width - 40, height: 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.windowText, .paragraphStyle: paragraph])
        }
    }
}

final class SyncGroupRow: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var links: [SyncClosureButton] = []
    private let countLabel = NSTextField(labelWithString: "")
    private var updateGlyph = false
    init(title: String, count: Int, action: SyncAction, color: NSColor, protected: Bool = false, actions: [(String, () -> Void)] = []) {
        super.init(frame: .zero)
        label.stringValue = title; label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = color
        let symbol: String
        switch action {
        case .conflict: symbol = "exclamationmark.triangle";
        case .trash: symbol = protected ? "minus.circle" : "trash";
        case .copy: symbol = "arrow.right";
        case .replace: symbol = "arrow.triangle.2.circlepath";
        case .mkdir: symbol = "folder.badge.plus"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); icon.contentTintColor = color
        addSubview(icon); addSubview(label)
        countLabel.stringValue = String(count); countLabel.font = .systemFont(ofSize: 12); countLabel.textColor = Theme.windowTextInactive;
        addSubview(countLabel)
        updateGlyph = action == .replace; icon.isHidden = updateGlyph
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(title + ", " + String(count))
        for (title, action) in actions {
            let link = SyncClosureButton(title: title); link.perform = action; link.drawsBackground = false; link.isBordered = false
            link.titleTint = Theme.activeText; link.font = .systemFont(ofSize: 11); addSubview(link); links.append(link)
        }
        if !links.isEmpty { setAccessibilityChildren(links) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if updateGlyph {
            ("≠" as NSString).draw(
                at: CGPoint(x: 0, y: 0), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: Theme.compareChanged])
        }
    }
    override func layout() {
        super.layout(); icon.frame = CGRect(x: 0, y: 4, width: 14, height: 14)
        var x = bounds.width - 40
        for link in links.reversed() {
            let width = (link.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 12
            x -= width; link.frame = CGRect(x: x, y: 1, width: width, height: 22); x -= 4
        }
        let titleWidth = min(max(60, x - 56), (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width + 2)
        label.frame = CGRect(x: 20, y: 3, width: titleWidth, height: 18)
        countLabel.frame = CGRect(x: 28 + titleWidth, y: 3, width: 32, height: 18)
    }
}

final class SyncIncludeCheckbox: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let rect = CGRect(x: 1, y: 4, width: 14, height: 14)
        let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        (state == .on ? Theme.activeText : Theme.viewBackground).withAlphaComponent(isEnabled ? 1 : 0.45).setFill(); box.fill()
        (state == .on ? Theme.activeText : Theme.frame).setStroke(); box.lineWidth = 1; box.stroke()
        if !title.isEmpty {
            (title as NSString).draw(
                at: CGPoint(x: 22, y: 4), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.windowText])
        }
        if state == .on {
            ("✓" as NSString).draw(
                at: CGPoint(x: 2, y: 3),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: ConflictActionButton.primaryTextColor])
        }
    }
}

final class SyncEmptyStateView: NSView {
    var title = "", method = ""
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let center = bounds.midX, top = max(0, bounds.midY - 50)
        Theme.compareOnly.withAlphaComponent(0.12).setFill(); NSBezierPath(ovalIn: CGRect(x: center - 20, y: top, width: 40, height: 40)).fill()
        ("✓" as NSString).draw(
            at: CGPoint(x: center - 10, y: top + 6),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: Theme.compareOnly])
        func line(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
            if title == "⚙︎",
                let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?.withSymbolConfiguration(
                    .init(pointSize: 15, weight: .regular, scale: .medium).applying(.init(paletteColors: [Theme.windowText])))
            {
                gear.draw(in: CGRect(x: bounds.midX - 7.5, y: bounds.midY - 7.5, width: 15, height: 15)); return
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let width = (text as NSString).size(withAttributes: attrs).width
            (text as NSString).draw(at: CGPoint(x: center - width / 2, y: y), withAttributes: attrs)
        }
        line(title, y: top + 52, font: .systemFont(ofSize: 15, weight: .semibold), color: Theme.windowText)
        line("Compared by " + method, y: top + 78, font: .systemFont(ofSize: 12), color: Theme.windowTextInactive)
    }
}

final class SyncPlanningSpinner: NSView {
    private let arc = CompareArcSpinner()
    private var timer: Timer?
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(arc); arc.setAccessibilityLabel("Planning"); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); arc.frame = bounds }
    func startAnimation(_ sender: Any?) {
        isHidden = false; arc.needsDisplay = true
        guard timer == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.arc.needsDisplay = true }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stopAnimation(_ sender: Any?) { timer?.invalidate(); timer = nil; isHidden = true }
    deinit { timer?.invalidate() }
}

final class SyncPresetChip: NSButton {
    override init(frame: NSRect) { super.init(frame: frame); setButtonType(.pushOnPushOff); isBordered = false }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero); self.title = title; self.target = target; self.action = action
        setAccessibilityRole(.checkBox); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        NSSize(width: (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 16, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        let chosen = state == .on
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (chosen ? Theme.activeText.withAlphaComponent(0.12) : Theme.viewBackground).setFill(); path.fill()
        (chosen ? Theme.activeText.withAlphaComponent(0.5) : Theme.frame).setStroke(); path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: chosen ? Theme.activeText : Theme.windowText,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        setAccessibilityValue(chosen ? 1 : 0)
    }
}

final class SyncOptionsPopup: NSButton {
    var onSelect: (() -> Void)?
    private var choices: [String] = []
    private(set) var indexOfSelectedItem = 0
    var titleOfSelectedItem: String? { choices.indices.contains(indexOfSelectedItem) ? choices[indexOfSelectedItem] : nil }
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; target = self; action = #selector(showChoices)
    }
    required init?(coder: NSCoder) { fatalError() }
    func addItems(withTitles titles: [String]) { choices = titles; needsDisplay = true }
    func selectItem(at index: Int) { indexOfSelectedItem = index; needsDisplay = true; setAccessibilityValue(titleOfSelectedItem) }
    @objc private func showChoices() {
        let menu = NSMenu()
        for (index, title) in choices.enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = index == indexOfSelectedItem ? .on : .off
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height), in: self)
    }
    @objc private func chose(_ item: NSMenuItem) { selectItem(at: item.tag); onSelect?() }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Theme.viewBackground.setFill(); path.fill(); Theme.frame.setStroke(); path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowText]
        let label = titleOfSelectedItem ?? ""
        let height = (label as NSString).size(withAttributes: attributes).height
        (label as NSString).draw(at: CGPoint(x: 8, y: (bounds.height - height) / 2), withAttributes: attributes)
        NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [Theme.windowTextInactive])))?
            .draw(in: CGRect(x: bounds.width - 20, y: (bounds.height - 10) / 2, width: 10, height: 10))
    }
}
