import AppKit
import PorpoiseCore
import PorpoiseServices

final class CompareView: NSView {
    private(set) var model: CompareModel
    let document: CompareRowsView
    let scroll = NSScrollView()
    let bar = TintedMaterialView(material: .titlebar, alpha: 0.82)
    let footer = TintedMaterialView(material: .titlebar, alpha: 0.82)
    let header = CompareHeaderView()
    let sync = CompareSyncButton(title: "Sync…", target: nil, action: nil)
    let close = CompareFocusButton(title: "×", target: nil, action: nil)
    let method = CompareFocusButton(title: "Size & date ⌄", target: nil, action: nil)
    let summary = NSTextField(labelWithString: "")
    let sizes = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "Comparing…")
    let stop = NSButton(title: "Stop", target: nil, action: nil)
    let zoom = CompareFocusSlider(value: 22, minValue: 16, maxValue: 48, target: nil, action: nil)
    private let overlay = ComparePlaceholder()
    private let revealAnimator = Animator()
    private var reveal: CGFloat = 1
    func animateIn() {
        reveal = 0
        revealAnimator.run(
            duration: 0.2,
            step: { [weak self] progress in
                self?.reveal = CGFloat(progress); self?.needsLayout = true
            })
    }
    func animateOut(_ completion: @escaping () -> Void) {
        model.stop()
        revealAnimator.run(
            duration: 0.24, curve: Animator.easeInCubic,
            step: { [weak self] progress in
                self?.reveal = CGFloat(1 - progress); self?.needsLayout = true
            }, completion: completion)
    }
    private var pills: [ComparePill] = []
    private var lastRowsVersion = -1
    private var popover: NSPopover?
    private var currentActivity: Activity?
    private var completedActivity: UUID?
    private var progressTicker: Timer?
    private let pause = NSButton(title: "Pause", target: nil, action: nil)
    private let jobLine = NSProgressIndicator()

    var onClose: (() -> Void)?
    var onSync: (() -> Void)?
    var onChoose: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onCompareFiles: ((SyncDifference) -> Void)?
    var lastUpdateMilliseconds: Double = 0
    init(model: CompareModel) {
        self.model = model; document = CompareRowsView(model: model)
        super.init(frame: .zero); wantsLayer = true
        header.document = document
        scroll.documentView = document; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        for child in [scroll, bar, header, footer, overlay] { addSubview(child) }
        let definitions: [(CompareFilter, String, NSColor)] = [
            (.onlyLeft, CompareSymbols.onlyLeft, Theme.compareOnly), (.onlyRight, CompareSymbols.onlyRight, Theme.compareOnly),
            (.changed, "≠", Theme.compareChanged),
            (.same, "=", Theme.windowTextInactive),
        ]
        for (filter, glyph, color) in definitions {
            let pill = ComparePill(filter: filter, glyph: glyph, color: color)
            pill.onToggle = { [weak self] in self?.model.toggle(filter) }
            bar.addSubview(pill); pills.append(pill)
        }
        for child in [sync, close, progress, progressLabel, stop, pause, jobLine] { bar.addSubview(child) }
        for child in [method, summary, sizes, zoom] { footer.addSubview(child) }
        sync.bezelStyle = .rounded; sync.controlSize = .small; sync.keyEquivalent = ""
        sync.contentTintColor = Theme.accent; sync.target = self; sync.action = #selector(syncPressed)
        close.isBordered = false; close.font = .systemFont(ofSize: 20); close.target = self; close.action = #selector(closePressed)
        close.toolTip = "Stop Comparing (⌃⌘C)"; close.setAccessibilityLabel("Stop Comparing")
        method.isBordered = false; method.font = .systemFont(ofSize: 12); method.target = self; method.action = #selector(methodPressed)
        summary.font = .systemFont(ofSize: 11); summary.textColor = Theme.windowTextInactive; summary.lineBreakMode = .byTruncatingTail
        sizes.font = .systemFont(ofSize: 11); sizes.textColor = Theme.windowTextInactive; sizes.alignment = .right
        progress.style = .spinning; progress.controlSize = .small; progress.isIndeterminate = true
        progressLabel.font = .systemFont(ofSize: 12); progressLabel.textColor = Theme.windowTextInactive
        pause.bezelStyle = .inline; pause.target = self; pause.action = #selector(pausePressed); pause.isHidden = true
        jobLine.style = .bar; jobLine.isIndeterminate = false; jobLine.minValue = 0; jobLine.maxValue = 1; jobLine.isHidden = true
        stop.bezelStyle = .inline; stop.target = self; stop.action = #selector(stopPressed)
        zoom.target = self; zoom.action = #selector(zoomChanged); zoom.controlSize = .mini; zoom.setAccessibilityLabel("Compare icon size")
        document.onExit = { [weak self] in self?.onClose?() }
        document.onPopover = { [weak self] row, rect in self?.showDetails(row, at: rect) }
        model.onChange = { [weak self] in self?.update() }
        Theme.whenChanged(self) { [weak self] in
            self?.update(); self?.document.needsDisplay = true; self?.header.needsDisplay = true
        }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func advanceKeyboardFocus(backward: Bool) {
        guard let window else { return }
        let controls: [NSView] = pills.filter { $0.isEnabled && !$0.isHidden } + [sync, pause, stop, close].filter { $0.isEnabled && !$0.isHidden }
        // The shared row surface has two logical focus stops; footer controls remain reachable too.
        var stops: [(view: NSView, side: SyncSide?)] = controls.map { ($0, nil) }
        stops += [(document, .left), (document, .right), (method, nil), (zoom, nil)]
        let current = stops.firstIndex { window.firstResponder === $0.view && ($0.side == nil || $0.side == document.activeSide) }
        let next = ((current ?? (backward ? 0 : -1)) + (backward ? -1 : 1) + stops.count) % stops.count
        if let side = stops[next].side { focusSide(side) } else { window.makeFirstResponder(stops[next].view) }
    }
    private func focusSide(_ side: SyncSide) {
        document.activeSide = side; window?.makeFirstResponder(document)
        let index = document.selectedPath.flatMap { model.rowIndices[$0] }
        if let index, (side == .left ? model.rows[index].left : model.rows[index].right) != nil {
            document.select(index)
        } else if let first = model.rows.firstIndex(where: { (side == .left ? $0.left : $0.right) != nil }) {
            document.select(first)
        }
        document.needsDisplay = true
    }
    /// Reuse native controls prepared during idle time; pair data and callbacks never carry over.
    func reset(model: CompareModel) {
        self.model.onChange = nil; self.model.stop()
        onClose = nil; onSync = nil; onChoose = nil; onIgnore = nil; onCompareFiles = nil
        document.onOpen = nil; document.onCopy = nil; document.onSelection = nil
        popover?.close(); popover = nil; currentActivity = nil; completedActivity = nil
        self.model = model; document.model = model
        document.selectedPath = nil; document.finishedPaths = []; document.hoverIndex = nil
        document.replaceRows([], indices: [:]); lastRowsVersion = -1
        scroll.contentView.scroll(to: .zero)
        model.onChange = { [weak self] in self?.update() }; update()
    }
    deinit { progressTicker?.invalidate() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let width = bounds.width
        let barHeight = 36 * reveal
        document.gutterWidth = 1 + 27 * reveal; header.gutterWidth = document.gutterWidth
        bar.frame = CGRect(x: 0, y: barHeight - 36, width: width, height: 36)
        header.frame = CGRect(x: 0, y: barHeight, width: width, height: 26)
        footer.frame = CGRect(x: 0, y: max(62, bounds.height - 28), width: width, height: 28)
        scroll.frame = CGRect(x: 0, y: 26 + barHeight, width: width, height: max(0, bounds.height - 54 - barHeight))
        document.frame.size = CGSize(
            width: scroll.contentSize.width, height: max(scroll.contentSize.height, CGFloat(document.rows.count) * document.rowHeight))
        var x: CGFloat = 10
        for pill in pills {
            pill.compact = width < 900; let desired = pill.intrinsicContentSize.width
            pill.frame = CGRect(x: x, y: 6, width: desired, height: 24); x += desired + 6
        }
        sync.frame = CGRect(x: width - 100, y: 5, width: 62, height: 26)
        close.frame = CGRect(x: width - 32, y: 5, width: 24, height: 24)
        progress.frame = CGRect(x: 12, y: 12, width: 12, height: 12)
        progressLabel.frame = CGRect(x: 32, y: 10, width: max(50, width - 210), height: 18)
        stop.frame = CGRect(x: width - 100, y: 7, width: 60, height: 22)
        pause.frame = CGRect(x: width - 172, y: 7, width: 66, height: 22)
        jobLine.frame = CGRect(x: 0, y: 34, width: width, height: 2)
        method.frame = CGRect(x: 6, y: 2, width: 120, height: 24)
        summary.frame = CGRect(x: 132, y: 7, width: max(50, width - (width < 780 ? 240 : 455)), height: 17)
        sizes.isHidden = width < 780
        sizes.frame = CGRect(x: width - 320, y: 7, width: 200, height: 17)
        zoom.frame = CGRect(x: width - 108, y: 7, width: 98, height: 16)
        overlay.frame = CGRect(x: max(8, (width - 460) / 2), y: max(80, (bounds.height - 185) / 2), width: min(460, width - 16), height: 185)
    }
    func update() {
        if model.loading && progressTicker == nil {
            progressTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }; self.document.setNeedsDisplay(self.document.seam.intersection(self.document.visibleRect))
            }
        } else if !model.loading {
            progressTicker?.invalidate(); progressTicker = nil
        }
        let started = CACurrentMediaTime()
        let labels = ["Only in \(model.names.0)", "Only in \(model.names.1)", "Changed", "Same"]
        for (index, pill) in pills.enumerated() {
            pill.count = model.outline?.counts[pill.filter.rawValue] ?? 0
            pill.label = labels[index]; pill.isOn = model.filter.contains(pill.filter)
            pill.isEnabled = pill.count > 0; pill.isHidden = model.showProgress; pill.needsDisplay = true
            pill.toolTip = "\(pill.label), \(pill.count) items"
            pill.setAccessibilityLabel("\(pill.label), \(pill.count) items, \(pill.isOn ? "showing" : "hidden")")
        }
        progress.isHidden = !model.showProgress; progressLabel.isHidden = !model.showProgress; stop.isHidden = !model.showProgress
        if model.showProgress {
            progress.startAnimation(nil); progressLabel.stringValue = "Comparing… \((model.comparison?.rows.count ?? 0).formatted()) items"
        } else {
            progress.stopAnimation(nil)
        }
        pause.isHidden = true
        jobLine.isHidden = !model.showProgress; jobLine.isIndeterminate = model.showProgress
        if model.showProgress { jobLine.startAnimation(nil) } else { jobLine.stopAnimation(nil) }
        sync.isHidden = model.showProgress; sync.isEnabled = model.comparison?.complete == true && model.error == nil && !model.loading
        if model.rowsVersion != lastRowsVersion {
            document.replaceRows(model.rows, indices: model.rowIndices); lastRowsVersion = model.rowsVersion
        } else {
            document.rows = model.rows; document.needsDisplay = true
        }
        method.title = Self.methodTitle(model.options.method) + " ⌄"
        if let error = model.error {
            pills.forEach { $0.isHidden = true }; progress.isHidden = true
            progressLabel.isHidden = false; progressLabel.stringValue = "Couldn't compare: " + error; progressLabel.textColor = Theme.compareDanger
            stop.isHidden = false; stop.title = "Try Again"; sync.isHidden = true
        } else {
            stop.title = "Stop"; progressLabel.textColor = Theme.windowTextInactive
        }
        header.needsDisplay = true
        let counts = model.outline?.counts ?? [:]
        let differences = [CompareFilter.onlyLeft, .onlyRight, .changed].reduce(0) { $0 + (counts[$1.rawValue] ?? 0) }
        let elapsed = model.elapsed < 0.1 ? "<0.1 s" : String(format: "%.1f s", model.elapsed)
        summary.stringValue =
            model.error
            ?? "\((model.comparison?.rows.count ?? 0).formatted()) items · \(differences.formatted()) differences · \(elapsed)"
        summary.textColor = model.error == nil ? Theme.windowTextInactive : Theme.compareDanger
        summary.toolTip = "Compared by \(Self.methodTitle(model.options.method).lowercased()) · \(summary.stringValue)"
        sizes.stringValue =
            "\(model.names.0) \(FileFormat.size(model.visibleLeftBytes)) · \(model.names.1) \(FileFormat.size(model.visibleRightBytes))"
        let identical = differences == 0 && model.comparison?.complete == true
        overlay.isHidden = !model.rows.isEmpty || model.loading || (model.comparison == nil && model.error == nil)
        overlay.configure(
            symbol: identical ? "checkmark.circle" : (model.error == nil ? "line.3.horizontal.decrease.circle" : "exclamationmark.triangle"),
            title: model.error != nil
                ? "Couldn't compare these folders"
                : (identical ? "\(model.names.0) and \(model.names.1) are identical" : "No items match these filters."),
            detail: model.error
                ?? (identical
                    ? "\((model.comparison?.rows.count ?? 0).formatted()) items match by \(Self.methodTitle(model.options.method).lowercased())."
                    : "Choose which differences to show above."),
            button: model.error != nil ? "Try Again" : (identical && model.options.method != .content ? "Compare Contents" : "Show All")
        ) { [weak self] in
            guard let self else { return }
            if self.model.error != nil {
                self.model.start()
            } else if identical && self.model.options.method != .content {
                self.model.options.method = .content; self.model.start()
            } else {
                self.model.filter = .all; self.model.rebuild()
            }
        }
        if let currentActivity { renderActivity(currentActivity) }
        needsLayout = true; lastUpdateMilliseconds = (CACurrentMediaTime() - started) * 1000
    }
    static func methodTitle(_ method: SyncCompareMethod) -> String {
        switch method {
        case .sizeAndDate: return "Size & date";
        case .sizeOnly: return "Size only";
        case .content: return "Contents"
        }
    }
    @objc private func syncPressed() { onSync?() }
    @objc private func closePressed() { onClose?() }
    @objc private func stopPressed() {
        if let currentActivity, !currentActivity.state.isEnded {
            FileOperationsController.shared.cancel(currentActivity)
        } else if model.error != nil {
            model.start()
        } else {
            model.stop()
        }
    }
    @objc private func pausePressed() {
        guard let currentActivity else { return }
        if currentActivity.state == .paused {
            FileOperationsController.shared.resume(currentActivity)
        } else {
            FileOperationsController.shared.pause(currentActivity)
        }
    }
    func show(activity: Activity) {
        currentActivity = activity
        model.suppressWatchUpdates = !activity.state.isEnded
        if activity.state.isEnded, completedActivity != activity.id {
            completedActivity = activity.id; model.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.currentActivity = nil; self?.update()
            }
        }
        renderActivity(activity)
    }
    private func renderActivity(_ activity: Activity) {
        pills.forEach { $0.isHidden = true }; sync.isHidden = true
        progress.isHidden = activity.state.isEnded; progressLabel.isHidden = false
        progressLabel.stringValue = (activity.state == .completed ? "✓ Synced · " : "") + activity.statusText
        progressLabel.textColor = activity.state == .failed ? Theme.compareDanger : Theme.windowText
        if !activity.state.isEnded { progress.startAnimation(nil) }
        pause.isHidden = !activity.canPause; pause.title = activity.state == .paused ? "Resume" : "Pause"
        stop.isHidden = activity.state.isEnded
        jobLine.isIndeterminate = false
        jobLine.isHidden = activity.state.isEnded; jobLine.doubleValue = activity.fraction
        jobLine.alphaValue = activity.state == .paused ? 0.4 : 1
    }
    @objc private func zoomChanged() {
        document.rowHeight = CGFloat(zoom.doubleValue) + 6
        document.frame.size.height = max(scroll.contentSize.height, CGFloat(document.rows.count) * document.rowHeight)
        document.needsDisplay = true
    }
    @objc func methodPressed() { showMethodMenu() }
    func showMethodMenu(capture: (() -> Void)? = nil) {
        let menu = NSMenu()
        for value in [SyncCompareMethod.sizeAndDate, .sizeOnly, .content] {
            let item = NSMenuItem(title: Self.methodTitle(value), action: #selector(chooseMethod(_:)), keyEquivalent: "")
            item.representedObject = value.rawValue; item.target = self; item.state = model.options.method == value ? .on : .off
            item.toolTip =
                value == .sizeAndDate
                ? "Fast. Times within 2 seconds count as equal."
                : (value == .content ? "Exact. Reads every file." : "For copies whose dates changed.")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let ignore = NSMenuItem(title: "Ignore…", action: #selector(ignorePressed), keyEquivalent: ""); ignore.target = self; menu.addItem(ignore)
        if let capture {
            let timer = Timer(timeInterval: 0.4, repeats: false) { _ in
                capture(); menu.cancelTracking()
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: method.bounds.height), in: method)
    }
    @objc private func chooseMethod(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = SyncCompareMethod(rawValue: raw) else { return }
        model.options.method = value; model.start()
    }
    @objc private func ignorePressed() { onIgnore?() }
    private func showDetails(_ row: SyncDifference, at rect: CGRect) {
        guard popover?.isShown != true else { return }
        let controller = NSViewController(); controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 290, height: 150))
        let title = NSTextField(labelWithString: (row.path as NSString).lastPathComponent); title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = CGRect(x: 12, y: 118, width: 266, height: 20); controller.view.addSubview(title)
        for (index, pair) in [(model.names.0, row.left), (model.names.1, row.right)].enumerated() {
            let label = NSTextField(labelWithString: "\(pair.0)   \(pair.1.map { FileFormat.size($0.size) } ?? "Not present")")
            label.font = .systemFont(ofSize: 11); label.frame = CGRect(x: 12, y: 92 - index * 22, width: 266, height: 18);
            controller.view.addSubview(label)
        }
        let compare = CompareActionButton(title: "Compare Files") { [weak self] in self?.onCompareFiles?(row) }
        compare.isEnabled = row.left?.kind == .file && row.right?.kind == .file
        compare.frame = CGRect(x: 10, y: 38, width: 140, height: 26); controller.view.addSubview(compare)
        for side in [SyncSide.left, .right] {
            let button = CompareActionButton(title: side == .left ? "Copy → \(model.names.1)" : "← Copy to \(model.names.0)") { [weak self] in
                self?.document.onCopy?(row, side); self?.popover?.close()
            }
            button.font = .systemFont(ofSize: 11); button.frame = CGRect(x: side == .left ? 10 : 150, y: 8, width: 130, height: 26)
            button.isEnabled = (side == .left ? row.left : row.right) != nil; controller.view.addSubview(button)
        }
        let popover = NSPopover(); popover.contentViewController = controller; popover.behavior = .transient; self.popover = popover
        popover.show(relativeTo: rect, of: document, preferredEdge: .maxX)
    }
}

final class ComparePill: NSButton {
    override var acceptsFirstResponder: Bool { true }
    let filter: CompareFilter
    let glyph: String
    let color: NSColor
    var label = "", count = 0, isOn = true, compact = false
    var onToggle: (() -> Void)?
    init(filter: CompareFilter, glyph: String, color: NSColor) {
        self.filter = filter; self.glyph = glyph; self.color = color; super.init(frame: .zero)
        isBordered = false; target = self; action = #selector(pressed); setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        let text = compact ? "\(glyph)  \(count.formatted())" : "\(glyph)  \(count.formatted())  \(label)"
        return CGSize(
            width: ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + 20, height: 24)
    }
    override func draw(_ dirty: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 12, yRadius: 12)
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState(); NSFocusRingPlacement.only.set(); box.fill(); NSGraphicsContext.restoreGraphicsState()
        }
        if isOn {
            color.withAlphaComponent(effectiveAppearance.isDark ? 0.2 : 0.16).setFill(); box.fill()
        } else {
            Theme.frame.setStroke(); box.stroke()
        }
        let text = compact ? "\(glyph)  \(count.formatted())" : "\(glyph)  \(count.formatted())  \(label)"
        (text as NSString).draw(
            at: CGPoint(x: 10, y: 4),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: (isOn ? color : Theme.windowTextInactive).withAlphaComponent(isEnabled ? 1 : 0.55),
            ])
    }
    @objc private func pressed() { onToggle?() }
}

final class CompareActionButton: NSButton {
    var clicked: (() -> Void)?
    init(title: String, clicked: @escaping () -> Void) {
        self.clicked = clicked; super.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self;
        action = #selector(performClickAction)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func performClickAction() { clicked?() }
}

final class ComparePlaceholder: NSView {
    private let image = NSImageView(), heading = NSTextField(labelWithString: ""), detail = NSTextField(wrappingLabelWithString: "")
    private let button = CompareActionButton(title: "Choose Folder…", clicked: {})
    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [image, heading, detail, button] { addSubview(view) }
        heading.font = .systemFont(ofSize: 15, weight: .semibold); heading.alignment = .center
        detail.font = .systemFont(ofSize: 12); detail.textColor = Theme.windowTextInactive; detail.alignment = .center
        image.contentTintColor = Theme.compareOnly; image.imageScaling = .scaleProportionallyUpOrDown
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    var onDrop: ((URL) -> Void)?
    func performPrimaryAction() { button.performClick(nil) }
    func configure(symbol: String, title: String, detail: String, button: String, action: @escaping () -> Void) {
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        heading.stringValue = title; self.detail.stringValue = detail; self.button.title = button; self.button.clicked = action; needsLayout = true
    }
    override func layout() {
        super.layout()
        image.frame = CGRect(x: (bounds.width - 48) / 2, y: 0, width: 48, height: 48)
        heading.frame = CGRect(x: 0, y: 62, width: bounds.width, height: 24)
        detail.frame = CGRect(x: 5, y: 92, width: bounds.width - 10, height: 44)
        button.frame = CGRect(x: (bounds.width - 180) / 2, y: 145, width: 180, height: 28)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onDrop == nil ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        onDrop?(url); return onDrop != nil
    }
}

final class CompareHeaderView: NSView {
    var gutterWidth: CGFloat = 28
    weak var document: CompareRowsView?
    private var drag: (side: SyncSide, second: Bool, combined: CGFloat)?
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        Theme.viewBackground.setFill(); bounds.fill()
        let width = (bounds.width - gutterWidth) / 2
        let style = NSMutableParagraphStyle(); style.alignment = .right
        for side in [SyncSide.left, .right] {
            let x: CGFloat = side == .left ? 0 : width + gutterWidth
            let columns = document?.widths(side, paneWidth: width) ?? (date: CGFloat(114), size: CGFloat(60))
            func title(_ string: String, _ role: ItemRole) -> String {
                guard document?.model.sortRole == role, document?.model.sortSide == side else { return string }
                return string + (document?.model.sortAscending == true ? "  ⌃" : "  ⌄")
            }
            (title("Name", .name) as NSString).draw(
                at: CGPoint(x: x + 12, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowTextInactive])
            if columns.date > 0 {
                (title("Modified", .modificationTime) as NSString).draw(
                    in: CGRect(x: x + width - columns.date, y: 6, width: columns.date - 10, height: 18),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowTextInactive, .paragraphStyle: style])
            }
            if columns.size > 0 {
                (title("Size", .size) as NSString).draw(
                    in: CGRect(x: x + width - columns.date - columns.size - 10, y: 6, width: columns.size, height: 18),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowTextInactive, .paragraphStyle: style])
            }
            Theme.hairline.setFill()
            for boundary in [x + width - columns.date - columns.size - 10, x + width - columns.date - 4] {
                CGRect(x: boundary, y: 6, width: 1, height: 14).fill()
            }
        }
        Theme.hairline.setFill(); CGRect(x: 0, y: 25, width: bounds.width, height: 1).fill()
        CGRect(x: width, y: 0, width: 1, height: 26).fill(); CGRect(x: width + gutterWidth - 1, y: 0, width: 1, height: 26).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        let point = convert(event.locationInWindow, from: nil), width = (bounds.width - gutterWidth) / 2
        let side: SyncSide = point.x < bounds.midX ? .left : .right
        let relative = point.x - (side == .left ? 0 : width + gutterWidth)
        let columns = document.widths(side, paneWidth: width)
        let first = width - columns.date - columns.size - 10, second = width - columns.date - 4
        if abs(relative - first) < 5 || abs(relative - second) < 5 {
            drag = (side, abs(relative - second) < 5, columns.date + columns.size); NSCursor.resizeLeftRight.set(); return
        }
        let role: ItemRole = relative > second ? .modificationTime : (relative > first ? .size : .name)
        document.model.sort(by: role, side: side); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag, let document else { return }
        let width = (bounds.width - gutterWidth) / 2,
            x = convert(event.locationInWindow, from: nil).x - (drag.side == .left ? 0 : width + gutterWidth)
        let size = document.widths(drag.side, paneWidth: width).size
        if drag.second {
            let date = max(70, min(drag.combined - 40, width - x - 4))
            document.dateWidths[drag.side] = date; document.sizeWidths[drag.side] = drag.combined - date
        } else {
            document.dateWidths[drag.side] = max(70, min(width - 180, width - x - size - 10))
        }
        needsDisplay = true; document.needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { drag = nil; NSCursor.arrow.set() }
    override func resetCursorRects() {
        let width = (bounds.width - gutterWidth) / 2
        for side in [SyncSide.left, .right] {
            let columns = document?.widths(side, paneWidth: width) ?? (date: CGFloat(114), size: CGFloat(60)),
                x: CGFloat = side == .left ? 0 : width + gutterWidth
            for boundary in [x + width - columns.date - columns.size - 10, x + width - columns.date - 4] {
                addCursorRect(CGRect(x: boundary - 4, y: 0, width: 8, height: 26), cursor: .resizeLeftRight)
            }
        }
    }
}

final class CompareSyncButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirty: NSRect) {
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState(); NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        Theme.accent.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        (title as NSString).draw(
            in: CGRect(x: 2, y: (bounds.height - 16) / 2, width: bounds.width - 4, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: Theme.increasedContrast ? Theme.selectionText : NSColor.white,
                .paragraphStyle: style,
            ])
    }
}

final class CompareFocusButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

final class CompareFocusSlider: NSSlider {
    override var acceptsFirstResponder: Bool { true }
}
