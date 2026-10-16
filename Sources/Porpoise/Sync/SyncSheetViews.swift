import AppKit
import PorpoiseCore
import PorpoiseServices

final class SyncSheetBackdrop: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func draw(_ dirtyRect: NSRect) { Theme.windowBackground.setFill(); bounds.fill() }
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
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let color = danger ? Theme.compareDanger : Theme.activeText
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        color.withAlphaComponent(Theme.increasedContrast ? 0.18 : 0.08).setFill(); path.fill()
        color.withAlphaComponent(0.4).setStroke(); path.lineWidth = 1; path.stroke()
        (text as NSString).draw(
            in: bounds.insetBy(dx: 12, dy: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowText])
    }
}
final class SyncClosureButton: ConflictActionButton {
    var perform: (() -> Void)?
    init(title: String) { super.init(frame: .zero); self.title = title; target = self; action = #selector(invoke); font = .systemFont(ofSize: 12) }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform?() }
}
final class SyncModeCard: NSButton {
    let mode: SyncMode
    var chosen = false
    var leftName = "", rightName = ""
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
        for x: CGFloat in [12, 46] { NSBezierPath(roundedRect: CGRect(x: x, y: 10, width: 16, height: 12), xRadius: 2, yRadius: 2).stroke() }
        let arrow = mode == .twoWay ? "⇄" : mode == .mirror ? "⇒" : "→"
        (arrow as NSString).draw(at: CGPoint(x: 29, y: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
        if chosen {
            ("✓" as NSString).draw(
                at: CGPoint(x: bounds.width - 24, y: 9),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.activeText])
        }
        (title as NSString).draw(
            at: CGPoint(x: 12, y: 28), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color])
        let detail =
            mode == .backup
            ? "Copy new and changed files to \(rightName). Never deletes."
            : mode == .mirror
                ? "Make \(rightName) match \(leftName). Extra items go to the Trash." : "Bring both sides up to date. Asks when both changed."
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
    private let include = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let path = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private var choices: NSSegmentedControl?
    init(step: SyncStep, pair: SavedSync, checked: Bool, choice: SyncOverride?, difference: SyncDifference? = nil, hasState: Bool = false) {
        self.step = step; self.pair = pair; self.difference = difference; super.init(frame: .zero)
        include.state = checked ? .on : .off; include.target = self; include.action = #selector(toggled)
        include.setAccessibilityLabel("Include \(step.path)")
        if step.sourcePath != nil, step.path != difference?.left?.path, step.path != difference?.right?.path {
            include.isEnabled = false; include.toolTip = "Both versions are kept together. Change the original item's choice to skip this group."
        }
        icon.image = NSImage(
            systemSymbolName: step.action == .mkdir ? "folder" : step.action == .trash ? "trash" : "doc", accessibilityDescription: nil)
        icon.contentTintColor = step.action == .trash ? Theme.compareDanger : Theme.windowTextInactive
        path.stringValue = step.path.isEmpty ? "Both folders" : step.path
        path.font = .systemFont(ofSize: 13); path.lineBreakMode = .byTruncatingMiddle; path.textColor = Theme.windowText
        size.stringValue = FileFormat.size(step.expectedSource?.size ?? step.expectedTarget?.size ?? 0)
        size.font = .systemFont(ofSize: 11); size.textColor = Theme.windowTextInactive; size.alignment = .right
        detail.stringValue =
            step.reason
            ?? (step.action == .copy
                ? "new"
                : step.action == .trash ? "only in \(step.target == .left ? pair.leftTitle : pair.rightTitle)" : "changed")
        detail.font = .systemFont(ofSize: 11); detail.textColor = Theme.windowTextInactive; detail.lineBreakMode = .byTruncatingTail
        [include, icon, path, detail, size].forEach(addSubview)
        if step.action == .conflict {
            let labels: [String]
            if let difference, difference.left?.kind != .directory, difference.right?.kind != .directory,
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
            if let choice, let index = choiceValues.firstIndex(of: choice) { choices.selectedSegment = index }
            choices.setAccessibilityLabel("Keep version from for \(step.path)")
            self.choices = choices; addSubview(choices)
            if difference?.left?.kind == .file && difference?.right?.kind == .file {
                compareButton.perform = { [weak self] in self?.compare() }; addSubview(compareButton)
            }
        }

        setAccessibilityElement(true); setAccessibilityRole(.row)
        setAccessibilityLabel("\(step.path), \(detail.stringValue), \(size.stringValue)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let width = max(200, bounds.width - 32)
        let conflict = step.action == .conflict
        include.frame = CGRect(x: 0, y: 2, width: 18, height: 20); include.isHidden = conflict
        icon.frame = CGRect(x: 22, y: 4, width: 16, height: 16)
        path.frame = CGRect(x: 46, y: 3, width: max(80, width - (conflict ? 290 : 270)), height: 18)
        if conflict {
            detail.frame = CGRect(x: 46, y: 24, width: width - 54, height: 16)
            let hasCompare = compareButton.superview != nil
            let choiceWidth: CGFloat = choices?.segmentCount == 1 ? 64 : (hasCompare ? 208 : 232)
            choices?.frame = CGRect(x: max(130, width - choiceWidth - (hasCompare ? 80 : 8)), y: 1, width: choiceWidth, height: 22)
            compareButton.frame = CGRect(x: width - 74, y: 1, width: 70, height: 22)
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
private final class SyncMenuItem: NSMenuItem {
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
    var source = "" { didSet { updateAccessibility() } }
    var destination = "" { didSet { updateAccessibility() } }
    private func updateAccessibility() {
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel("From \(source) to \(destination)")
    }
    override var isFlipped: Bool { true }
    private var chipWidth: CGFloat { (bounds.width - 88) / 2 }
    var swapRect: CGRect { CGRect(x: 44 + chipWidth + 8, y: 0, width: 28, height: 28) }
    override func draw(_ dirtyRect: NSRect) {
        ("From" as NSString).draw(
            at: CGPoint(x: 0, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.windowTextInactive])
        for (index, title) in [source, destination].enumerated() {
            let box = CGRect(x: 44 + CGFloat(index) * (chipWidth + 44), y: 0, width: chipWidth, height: 28)
            Theme.viewBackground.setFill(); NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
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
    init(title: String, action: SyncAction, color: NSColor) {
        super.init(frame: .zero)
        label.stringValue = title; label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = color
        let symbol: String
        switch action {
        case .conflict: symbol = "exclamationmark.triangle";
        case .trash: symbol = "trash";
        case .copy: symbol = "arrow.right";
        case .replace: symbol = "arrow.triangle.2.circlepath";
        case .mkdir: symbol = "folder.badge.plus"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); icon.contentTintColor = color
        addSubview(icon); addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout(); icon.frame = CGRect(x: 0, y: 4, width: 14, height: 14)
        label.frame = CGRect(x: 20, y: 3, width: max(100, bounds.width - 28), height: 18)
    }
}
