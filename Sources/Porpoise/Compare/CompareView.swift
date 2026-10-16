import AppKit
import PorpoiseCore
import PorpoiseServices

private struct CompareJobBarState {
    var state: Activity.State
    var completed: Int, total: Int
    var fraction: Double
    var canPause: Bool
    var destination: String, mode: String
    var copied: Int, trashed: Int, errors: Int
    var reason: String
    var lostConnection: Bool
    var amounts: String = "", timeLeft: String = ""
}

final class CompareView: NSView {
    private(set) var model: CompareModel
    let document: CompareRowsView
    let scroll = NSScrollView()
    let bar = TintedMaterialView(material: .titlebar, alpha: 0.82)
    let footer = TintedMaterialView(material: .titlebar, alpha: 0.82)
    let header = CompareHeaderView()
    let sync = SyncClosureButton(title: "Sync…")
    let close = CompareFocusButton(title: "×", target: nil, action: nil)
    let method = CompareFocusButton(title: "Size & date ⌄", target: nil, action: nil)
    let summary = NSTextField(labelWithString: "")
    let sizes = NSTextField(labelWithString: "")
    private let methodSeparator = NSView()
    private let smallZoom = ZoomGlyph(large: false), largeZoom = ZoomGlyph(large: true)
    let progress = CompareArcSpinner()
    let progressLabel = NSTextField(labelWithString: "Comparing…")
    let stop = ComparePrimaryButton(title: "Stop", clicked: {})
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
    private var activityPaintTimer: Timer?
    private var lastActivityPaint: CFTimeInterval = 0
    private var lastActivityState: Activity.State?
    private var laidOutActivityState: Activity.State?
    private(set) var activityNotificationCount = 0, activityPaintCount = 0
    private var jobMetadata: [AnyHashable: Any] = [:]
    private var reviewJob: CompareJobBarState?
    private let jobWash = NSView(), jobSymbol = NSImageView()
    private let showJob = CompareFocusButton(title: "Show", target: nil, action: nil)
    private var completedActivity: UUID?
    private var activityDismissal: DispatchWorkItem?
    private var progressTicker: Timer?
    private let pause = ComparePrimaryButton(title: "Pause", clicked: {})
    private let jobLine = CompareProgressLine()

    var onClose: (() -> Void)?
    var onSync: (() -> Void)?
    var onChoose: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onCompareFiles: ((SyncDifference) -> Void)?
    var onMissingRoot: ((SyncSide?) -> Void)?
    var lastUpdateMilliseconds: Double = 0
    init(model: CompareModel) {
        self.model = model; document = CompareRowsView(model: model)
        super.init(frame: .zero); wantsLayer = true
        header.document = document
        scroll.documentView = document; scroll.drawsBackground = false; scroll.hasVerticalScroller = false
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
        jobWash.wantsLayer = true; bar.addSubview(jobWash)
        for child in [sync, close, progress, progressLabel, stop, pause, showJob, jobSymbol, jobLine] { bar.addSubview(child) }
        showJob.isBordered = false; showJob.font = .systemFont(ofSize: 12); showJob.contentTintColor = Theme.accent
        showJob.target = self; showJob.action = #selector(showJobPressed); showJob.isHidden = true; jobSymbol.isHidden = true
        bar.addSubview(method)
        for child in [methodSeparator, summary, sizes, smallZoom, zoom, largeZoom] { footer.addSubview(child); child.isHidden = true }
        method.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?.withSymbolConfiguration(
            .init(pointSize: 14, weight: .regular))
        method.imagePosition = .imageLeft; method.imageHugsTitle = true
        method.contentTintColor = Theme.windowTextInactive
        methodSeparator.wantsLayer = true
        Theme.whenChanged(methodSeparator) { [weak methodSeparator] in methodSeparator?.layer?.backgroundColor = Theme.hairline.cgColor }
        smallZoom.onClick = { [weak self] in
            guard let self else { return }; self.zoom.doubleValue = max(16, self.zoom.doubleValue - 4); self.zoomChanged()
        }
        largeZoom.onClick = { [weak self] in
            guard let self else { return }; self.zoom.doubleValue = min(48, self.zoom.doubleValue + 4); self.zoomChanged()
        }
        sync.primary = true
        sync.bezelStyle = .rounded; sync.controlSize = .small; sync.keyEquivalent = ""
        sync.contentTintColor = Theme.accent; sync.target = self; sync.action = #selector(syncPressed)
        close.isBordered = false; close.font = .systemFont(ofSize: 20); close.target = self; close.action = #selector(closePressed)
        close.toolTip = "Stop Comparing (⌃⌘C)"; close.setAccessibilityLabel("Stop Comparing")
        method.isBordered = false; method.font = .systemFont(ofSize: 12); method.target = self; method.action = #selector(methodPressed)
        summary.font = .systemFont(ofSize: 11); summary.textColor = Theme.windowTextInactive; summary.lineBreakMode = .byTruncatingTail
        sizes.font = .systemFont(ofSize: 11); sizes.textColor = Theme.windowTextInactive; sizes.alignment = .right
        progressLabel.font = .systemFont(ofSize: 12); progressLabel.textColor = Theme.windowTextInactive
        pause.bezelStyle = .rounded; pause.font = .systemFont(ofSize: 12); pause.target = self; pause.action = #selector(pausePressed);
        pause.isPrimary = false; stop.isPrimary = false
        pause.isHidden = true
        jobLine.isHidden = true
        jobLine.onFrame = { [weak self] in self?.progress.needsDisplay = true }
        stop.bezelStyle = .rounded; stop.font = .systemFont(ofSize: 12); stop.target = self; stop.action = #selector(stopPressed)
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
        let controls: [NSView] =
            pills.filter { $0.isEnabled && !$0.isHidden } + [sync, pause, stop, showJob, close].filter { $0.isEnabled && !$0.isHidden }
        // The shared row surface has two logical focus stops; footer controls remain reachable too.
        var stops: [(view: NSView, side: SyncSide?)] = controls.map { ($0, nil) }
        if document.detailsContainers.count == 2 {
            stops += [(document.detailsContainers[0].list, .left), (document.detailsContainers[1].list, .right)]
        } else {
            stops += [(document, .left), (document, .right)]
        }
        stops += [(method, nil)]
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
        onClose = nil; onSync = nil; onChoose = nil; onIgnore = nil; onCompareFiles = nil; onMissingRoot = nil
        document.onOpen = nil; document.onCopy = nil; document.onSelection = nil
        popover?.close(); popover = nil; currentActivity = nil; completedActivity = nil; jobMetadata = [:]; reviewJob = nil
        activityPaintTimer?.invalidate(); activityPaintTimer = nil; lastActivityPaint = 0; lastActivityState = nil; laidOutActivityState = nil
        activityNotificationCount = 0; activityPaintCount = 0
        activityDismissal?.cancel(); activityDismissal = nil
        self.model = model; document.model = model
        document.selectedPath = nil; document.finishedPaths = []; document.failedPaths = []; document.hoverIndex = nil
        document.replaceRows([], indices: [:]); lastRowsVersion = -1
        scroll.contentView.scroll(to: .zero)
        model.onChange = { [weak self] in self?.update() }; update()
    }
    deinit { progressTicker?.invalidate(); activityPaintTimer?.invalidate(); activityDismissal?.cancel() }
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
        let detailsWidth = (scroll.frame.width - document.gutterWidth) / 2
        for (index, container) in document.detailsContainers.enumerated() {
            if container.scroll.superview !== self { addSubview(container.scroll, positioned: .above, relativeTo: scroll) }
            container.scroll.frame = CGRect(
                x: index == 0 ? 0 : detailsWidth + document.gutterWidth, y: scroll.frame.minY, width: detailsWidth, height: scroll.frame.height)
        }
        document.layoutDetails(); header.needsLayout = true; header.layoutSubtreeIfNeeded()
        var x: CGFloat = 10
        let fullPillWidth = pills.reduce(CGFloat(0)) { total, pill in
            pill.compact = false; return total + pill.intrinsicContentSize.width + 6
        }
        for pill in pills {
            pill.compact = fullPillWidth > width - 290; let desired = pill.intrinsicContentSize.width
            pill.frame = CGRect(x: x, y: 6, width: desired, height: 24); x += desired + 6
        }
        sync.frame = CGRect(x: width - 100, y: 5, width: 62, height: 26)
        close.frame = CGRect(x: width - 32, y: 5, width: 24, height: 24)
        progress.frame = CGRect(x: width - 269, y: 12, width: 12, height: 12)
        progressLabel.frame = CGRect(x: 32, y: 10, width: max(50, width - 210), height: 18)
        let stopWidth = max(68, stop.intrinsicContentSize.width + 24), pauseWidth = max(80, pause.intrinsicContentSize.width + 24)
        let trailing: CGFloat = close.isHidden ? 12 : 40
        stop.frame = CGRect(x: width - trailing - stopWidth, y: 3, width: stopWidth, height: 30)
        pause.frame = CGRect(x: stop.frame.minX - 8 - pauseWidth, y: 3, width: pauseWidth, height: 30)
        if !stop.isHidden { progressLabel.frame.size.width = max(50, (pause.isHidden ? stop.frame.minX : pause.frame.minX) - 48) }
        jobLine.frame = CGRect(x: 0, y: 0, width: width, height: 2)
        jobWash.frame = bar.bounds; jobSymbol.frame = CGRect(x: 11, y: 10, width: 16, height: 16)
        let completedJob =
            (currentActivity?.state.isEnded == true && currentActivity?.state != .failed)
            || (reviewJob?.state.isEnded == true && reviewJob?.state != .failed)
        showJob.frame = CGRect(x: completedJob ? width - 164 : stop.frame.minX - 60, y: 6, width: completedJob ? 130 : 44, height: 24)
        if !showJob.isHidden { progressLabel.frame.size.width = max(50, showJob.frame.minX - 48) }
        method.frame = CGRect(x: width - 252, y: 6, width: 140, height: 24)
        methodSeparator.frame = CGRect(x: 148, y: 6, width: 1, height: 16)
        summary.frame = CGRect(x: 160, y: 7, width: max(50, width - (width < 780 ? 320 : 515)), height: 17)
        sizes.isHidden = true
        sizes.frame = CGRect(x: width - 360, y: 7, width: 200, height: 17)
        smallZoom.frame = CGRect(x: width - 150, y: 4, width: 20, height: 20)
        zoom.frame = CGRect(x: width - 130, y: 7, width: 106, height: 16)
        largeZoom.frame = CGRect(x: width - 24, y: 4, width: 20, height: 20)
        let paneWidth = (width - document.gutterWidth) / 2
        for (index, container) in document.detailsContainers.enumerated() {
            if container.statusBar.superview !== footer { footer.addSubview(container.statusBar) }
            container.statusBar.frame = CGRect(x: index == 0 ? 0 : paneWidth + document.gutterWidth, y: 0, width: paneWidth, height: 28)
        }
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
            pill.isEnabled = pill.count > 0; pill.isHidden = false; pill.needsDisplay = true
            pill.toolTip =
                "\(pill.label), \(FileFormat.count(pill.count)) items\n\(index == 0 ? model.leftRoot.path : (index == 1 ? model.rightRoot.path : model.leftRoot.path + " ⇄ " + model.rightRoot.path))"
            pill.setAccessibilityLabel("\(pill.label), \(FileFormat.count(pill.count)) items, \(pill.isOn ? "showing" : "hidden")")
        }
        progress.isHidden = !model.showProgress; progressLabel.isHidden = true; stop.isHidden = true
        if model.showProgress {
            progress.startAnimation(nil)
            let count = FileFormat.count(model.comparison?.rows.count ?? 0), text = "Comparing… \(count) items"
            let run = NSMutableAttributedString(
                string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.windowTextInactive])
            run.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .semibold), range: (text as NSString).range(of: count))
            progressLabel.attributedStringValue = run
        } else {
            progress.stopAnimation(nil)
        }
        pause.isHidden = true
        close.isHidden = false; showJob.isHidden = true; jobSymbol.isHidden = true; jobWash.layer?.backgroundColor = nil
        jobLine.isHidden = !model.showProgress; jobLine.isIndeterminate = model.showProgress
        if model.showProgress { jobLine.startAnimation(nil) } else { jobLine.stopAnimation(nil) }
        sync.isHidden = false; sync.isEnabled = model.comparison?.complete == true && model.error == nil && !model.loading
        if model.rowsVersion != lastRowsVersion {
            document.replaceRows(model.rows, indices: model.rowIndices); lastRowsVersion = model.rowsVersion
        } else {
            document.rows = model.rows; document.needsDisplay = true
        }
        document.updateDetails()
        method.isHidden = false
        method.title = Self.methodTitle(model.options.method) + " ⌄"
        method.toolTip = model.loading ? "Comparing…" : summary.stringValue
        if !model.loading, model.comparison?.complete == false, model.error == nil {
            method.toolTip = "A linked folder is missing. Go back or up to continue comparing; Sync is unavailable."
        }
        if let error = model.error {
            pills.forEach { $0.isHidden = true }; progress.isHidden = true
            progressLabel.isHidden = false; progressLabel.stringValue = "Couldn't compare: " + error; progressLabel.textColor = Theme.compareDanger
            stop.isHidden = false; stop.title = "Try Again"; sync.isHidden = true
        } else {
            stop.title = "Stop"; stop.image = nil; progressLabel.textColor = Theme.windowTextInactive
        }
        header.needsDisplay = true
        let counts = model.outline?.counts ?? [:]
        let differences = [CompareFilter.onlyLeft, .onlyRight, .changed].reduce(0) { $0 + (counts[$1.rawValue] ?? 0) }
        let elapsed = model.elapsed < 0.1 ? "<0.1 s" : String(format: "%.1f s", model.elapsed)
        let differenceSummary = differences == 0 ? "no differences" : "\(FileFormat.count(differences)) differences"
        summary.stringValue =
            model.error
            ?? "\(FileFormat.count(model.comparison?.rows.count ?? 0)) items · \(differenceSummary) · \(elapsed)"
        if model.loading {
            summary.stringValue =
                "Reading \(model.options.method == .content ? "contents" : "folders")… \(FileFormat.count(model.comparison?.rows.count ?? 0)) items"
        }
        summary.textColor = model.error == nil ? Theme.windowTextInactive : Theme.compareDanger
        summary.toolTip = "Compared by \(Self.methodTitle(model.options.method).lowercased()) · \(summary.stringValue)"
        sizes.isHidden = model.loading || model.comparison == nil
        sizes.stringValue =
            "\(model.names.0) \(FileFormat.size(model.outline?.totalBytes[.left] ?? 0)) · \(model.names.1) \(FileFormat.size(model.outline?.totalBytes[.right] ?? 0))"
        let identical = differences == 0 && model.comparison?.complete == true
        overlay.isHidden = model.error == nil || !model.rows.isEmpty || model.loading
        overlay.configure(
            symbol: identical ? "checkmark.circle" : (model.error == nil ? "line.3.horizontal.decrease.circle" : "exclamationmark.triangle"),
            title: model.error != nil
                ? "Couldn't compare these folders"
                : (identical ? "\(model.names.0) and \(model.names.1) are identical" : "No items match these filters."),
            detail: model.error
                ?? (identical
                    ? "\(FileFormat.count(model.comparison?.rows.count ?? 0)) items match by \(Self.methodTitle(model.options.method).lowercased().replacingOccurrences(of: "&", with: "and"))."
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
        if !model.loading, let comparison = model.comparison {
            let missing: SyncSide? =
                model.leftRoot.isFileURL && comparison.leftRootIdentity == nil
                ? .left : (model.rightRoot.isFileURL && comparison.rightRootIdentity == nil ? .right : nil)
            onMissingRoot?(missing)
        }
        overlay.button.isPrimary = !identical
        if let currentActivity { renderActivity(currentActivity) }
        if let reviewJob { renderJob(reviewJob) }
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
    @objc private func closePressed() {
        if currentActivity?.state.isEnded == true || reviewJob?.state.isEnded == true {
            activityDismissal?.cancel(); activityDismissal = nil
            currentActivity = nil; reviewJob = nil; jobMetadata = [:]; document.finishedPaths = []; document.failedPaths = []; update()
        } else {
            onClose?()
        }
    }
    @objc private func stopPressed() {
        if currentActivity?.state == .failed, let currentActivity {
            FileOperationsController.shared.retry(currentActivity, window: window); return
        }
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
    @objc private func showJobPressed() { ActivityWindowController.shared.show() }
    func show(activity: Activity, metadata: [AnyHashable: Any] = [:]) {
        activityNotificationCount += 1
        jobMetadata = metadata
        currentActivity = activity
        model.suppressWatchUpdates = !activity.state.isEnded
        if !activity.state.isEnded {
            completedActivity = nil; activityDismissal?.cancel(); activityDismissal = nil
        } else if completedActivity != activity.id {
            completedActivity = activity.id; model.start()
            if activity.state != .failed {
                let terminalState = activity.state
                let dismissal = DispatchWorkItem { [weak self] in
                    guard let self, self.currentActivity?.id == activity.id, self.currentActivity?.state == terminalState else { return }
                    self.currentActivity = nil; self.document.finishedPaths = []; self.update()
                }
                activityDismissal?.cancel(); activityDismissal = dismissal
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismissal)
            }
        }
        let now = CACurrentMediaTime()
        if activity.state != lastActivityState || now - lastActivityPaint >= 0.25 {
            paintActivity()
        } else if activityPaintTimer == nil {
            let timer = Timer(timeInterval: max(0.001, 0.25 - (now - lastActivityPaint)), repeats: false) { [weak self] _ in
                self?.paintActivity()
            }
            activityPaintTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func paintActivity() {
        activityPaintTimer?.invalidate(); activityPaintTimer = nil
        guard let currentActivity else { return }
        lastActivityPaint = CACurrentMediaTime(); lastActivityState = currentActivity.state
        activityPaintCount += 1
        renderActivity(currentActivity)
        document.setNeedsDisplay(currentActivity.state == .failed ? document.visibleRect : document.seam.intersection(document.visibleRect))
    }
    private func renderActivity(_ activity: Activity) {
        renderJob(
            CompareJobBarState(
                state: activity.state,
                completed: jobMetadata["completedItems"] as? Int ?? activity.planProgress?.completedSteps ?? activity.progress?.doneItems ?? 0,
                total: jobMetadata["totalItems"] as? Int ?? activity.planProgress?.totalSteps ?? activity.progress?.totalItems ?? 0,
                fraction: activity.fraction,
                canPause: activity.canPause, destination: jobMetadata["destinationLabel"] as? String ?? model.names.1,
                mode: jobMetadata["modeLabel"] as? String ?? "Sync", copied: jobMetadata["completedCopied"] as? Int ?? 0,
                trashed: jobMetadata["completedTrashed"] as? Int ?? 0,
                errors: max(activity.errors.count, (jobMetadata["failedPaths"] as? [String])?.count ?? 0),
                reason: activity.errors.first ?? "", lostConnection: jobMetadata["lostConnection"] as? Bool ?? false))
    }
    func previewJob(_ state: String) {
        guard Settings.isTesting else { return }
        if state == "off" { reviewJob = nil; update(); return }
        let value = Activity.State(rawValue: state) ?? .running
        reviewJob = CompareJobBarState(
            state: value, completed: value == .completed ? 24 : 12, total: 24, fraction: 0.5,
            canPause: !value.isEnded, destination: model.names.1, mode: "Mirror", copied: 22, trashed: 2,
            errors: value == .failed ? 3 : 0, reason: "Backup is full.", lostConnection: state == "connection")
        reviewJob?.amounts = "18.4 of 48.2 MB"; reviewJob?.timeLeft = "about 6 s left"
        if value == .failed, let path = model.rows.first(where: { ($0.left ?? $0.right)?.kind == .file })?.path {
            document.failedPaths = [path]; document.needsDisplay = true
        } else {
            document.failedPaths = []
        }
        update()
    }
    private func renderJob(_ job: CompareJobBarState) {
        pills.forEach { $0.isHidden = true }; sync.isHidden = true; method.isHidden = true
        let paused = job.state == .paused, failed = job.state == .failed, done = job.state == .completed
        let stopped = job.state == .cancelled || job.state == .interrupted
        progress.isHidden = job.state.isEnded || paused || job.lostConnection; progressLabel.isHidden = false
        let title: String, detail: String, symbol: String?, color: NSColor
        if job.lostConnection {
            title = "Lost connection to \(job.destination)."; detail = "Finished items are kept."; symbol = "exclamationmark.triangle.fill";
            color = Theme.compareChanged
        } else if failed {
            title = "\(FileFormat.count(max(1, job.errors))) \(job.errors == 1 ? "item couldn’t" : "items couldn’t") be copied."
            detail = job.reason; symbol = "exclamationmark.circle.fill"; color = Theme.compareDanger
        } else if done {
            title = "Synced"
            var parts: [String] = []
            if job.copied > 0 { parts.append("\(FileFormat.count(job.copied)) copied") }
            if job.trashed > 0 { parts.append("\(FileFormat.count(job.trashed)) moved to the Trash") }
            parts.append("just now"); detail = parts.joined(separator: " · "); symbol = "checkmark";
            color = Theme.compareOnly
        } else if stopped {
            title = job.state == .cancelled ? "Stopped" : "Interrupted"
            detail = "\(job.completed) of \(job.total) completed · Finished files kept"
            symbol = "stop.circle"; color = Theme.windowTextInactive
        } else if paused {
            title = "Paused"; detail = "\(FileFormat.count(job.completed)) of \(FileFormat.count(job.total)) done"; symbol = "pause.fill";
            color = Theme.windowTextInactive
        } else {
            title = job.state == .waiting ? "Waiting for your answer" : "Syncing to \(job.destination)"
            detail = "\(FileFormat.count(job.completed)) of \(FileFormat.count(job.total))"; symbol = nil; color = Theme.accent
        }
        var text = title + (detail.isEmpty ? "" : (failed || job.lostConnection ? " " : " · ") + detail)
        if !job.state.isEnded, !job.amounts.isEmpty { text += " · " + job.amounts }
        if job.state == .running, !job.timeLeft.isEmpty { text += " · " + job.timeLeft }
        if !job.state.isEnded, let totalBytes = jobMetadata["totalBytes"] as? Int64, totalBytes > 0,
            let completedBytes = jobMetadata["completedBytes"] as? Int64
        {
            text += " · \(FileFormat.size(completedBytes)) of \(FileFormat.size(totalBytes))"
        }
        let run = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.windowText])
        run.addAttribute(
            .font, value: NSFont.systemFont(ofSize: 12, weight: .semibold), range: NSRange(location: 0, length: (title as NSString).length))
        progressLabel.attributedStringValue = run
        jobSymbol.isHidden = symbol == nil; jobSymbol.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        jobSymbol.contentTintColor = color; jobWash.layer?.backgroundColor = failed ? Theme.compareDanger.withAlphaComponent(0.1).cgColor : nil
        if !progress.isHidden { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        close.isHidden = !job.state.isEnded
        pause.isHidden = job.state.isEnded || (!job.canPause && !job.lostConnection); pause.title = paused || job.lostConnection ? "Resume" : "Pause"
        pause.image = NSImage(systemSymbolName: paused || job.lostConnection ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        pause.imagePosition = .imageLeft; pause.imageHugsTitle = true;
        pause.contentTintColor = paused || job.lostConnection ? Theme.accent : Theme.windowText
        pause.isPrimary = paused || job.lostConnection
        stop.isHidden = job.state.isEnded && !failed; stop.title = failed ? "Try Again" : "Stop"
        stop.image = failed ? nil : NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stop.imagePosition = .imageLeft; stop.imageHugsTitle = true
        showJob.isHidden = !job.state.isEnded; showJob.title = done || stopped ? "Show in Activity" : "Show"
        let pair = jobMetadata["pairDescription"] as? String ?? "\(model.names.0) → \(job.destination)"
        summary.stringValue = "\(job.mode) · \(pair)"
        jobLine.isIndeterminate = false
        jobLine.isHidden = job.state.isEnded; jobLine.doubleValue = job.fraction
        jobLine.alphaValue = paused ? 0.4 : 1
        if job.state.isEnded { jobLine.stopAnimation(nil) } else { jobLine.startAnimation(nil) }
        if laidOutActivityState != job.state { laidOutActivityState = job.state; needsLayout = true }
    }
    @objc private func zoomChanged() {
        for container in document.detailsContainers {
            var props = container.model.props; props.setIconSize(CGFloat(zoom.doubleValue), for: .details); container.model.props = props
        }
        document.rowHeight = 2 * ItemListView.pad + max(CGFloat(zoom.doubleValue), document.detailsContainers.first?.list.lineHeight ?? 16) + 2
        document.layoutDetails()
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
                : (value == .content
                    ? "Exact. \(model.leftRoot.isFileURL && model.rightRoot.isFileURL ? "Reads every file" : "Downloads files") that might differ."
                    : "For copies whose dates changed.")
            item.subtitle = item.toolTip
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
        let controller = NSViewController(); controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 172))
        let title = NSTextField(labelWithString: (row.path as NSString).lastPathComponent); title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = CGRect(x: 12, y: 138, width: 286, height: 22); controller.view.addSubview(title)
        let status: String
        switch row.status {
        case .same: status = "Same"
        case .onlyLeft, .onlyRight: status = "Only here"
        case .collision: status = "Name collision"
        case .changed: status = "Changed"
        }
        let state = NSTextField(labelWithString: status); state.font = .systemFont(ofSize: 11, weight: .medium)
        state.textColor = document.color(row); state.alignment = .right
        state.frame = CGRect(x: 300, y: 140, width: 108, height: 18); controller.view.addSubview(state)
        for (index, pair) in [(model.names.0, row.left), (model.names.1, row.right)].enumerated() {
            let date = pair.1?.modified.map { Settings.shared.dateStyle == .relative ? FileFormat.relativeDate($0) : FileFormat.longDate($0) } ?? ""
            let newer: Bool
            if case .changed(let change) = row.status { newer = index == 0 ? change == .newerLeft : change == .newerRight } else { newer = false }
            let values = [pair.0, pair.1.map { FileFormat.size($0.size) } ?? "Not present", date + (newer ? "  ← newer" : "")]
            for (column, value) in values.enumerated() {
                let label = NSTextField(labelWithString: value); label.font = .systemFont(ofSize: 11)
                label.lineBreakMode = .byTruncatingMiddle; label.toolTip = value
                label.frame = CGRect(x: [12, 162, 230][column], y: 110 - index * 24, width: [142, 62, 178][column], height: 18)
                controller.view.addSubview(label)
            }
        }
        let compare = SyncClosureButton(title: "Compare Files ⌥⌘Y")
        compare.perform = { [weak self] in
            self?.popover?.close(); self?.onCompareFiles?(row)
        }
        compare.isEnabled = row.left?.kind == .file && row.right?.kind == .file
        compare.frame = CGRect(x: 12, y: 46, width: 190, height: 28); controller.view.addSubview(compare)
        for side in [SyncSide.left, .right] {
            let button = SyncClosureButton(title: side == .left ? "Copy → \(model.names.1)" : "← Copy to \(model.names.0)")
            button.perform = { [weak self] in
                self?.document.onCopy?(row, side); self?.popover?.close()
            }
            button.font = .systemFont(ofSize: 11); button.frame = CGRect(x: side == .left ? 12 : 216, y: 10, width: 192, height: 28)
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
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let countWidth = (FileFormat.count(count) as NSString).size(withAttributes: [.font: font]).width
        let labelWidth = compact ? 0 : 8 + (label as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: ceil(40 + countWidth + labelWidth), height: 24)
    }
    override func draw(_ dirty: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 12, yRadius: 12)
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState(); NSFocusRingPlacement.only.set(); box.fill(); NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(!isEnabled ? 0.5 : (isOn ? 1 : 0.55))
        if isOn {
            color.withAlphaComponent(effectiveAppearance.isDark ? 0.2 : 0.16).setFill(); box.fill()
        } else {
            Theme.frame.setStroke(); box.stroke()
        }
        if Theme.increasedContrast {
            (isOn ? color : Theme.frame).setStroke(); box.lineWidth = 1.5; box.stroke()
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        if filter == .onlyLeft || filter == .onlyRight {
            CompareSymbols.drawOnly(filter == .onlyLeft ? .left : .right, centeredAt: CGPoint(x: 17, y: bounds.midY), color: color)
        } else {
            (glyph as NSString).draw(
                at: CGPoint(x: 10, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: color])
        }
        let count = FileFormat.count(count) as NSString, attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        count.draw(at: CGPoint(x: 30, y: 4), withAttributes: attributes)
        if !compact {
            (label as NSString).draw(
                at: CGPoint(x: 38 + count.size(withAttributes: attributes).width, y: 4),
                withAttributes: [.font: font, .foregroundColor: Theme.windowText])
        }
    }
    @objc private func pressed() { onToggle?() }
}

class CompareActionButton: NSButton {
    var clicked: (() -> Void)?
    init(title: String, clicked: @escaping () -> Void) {
        self.clicked = clicked; super.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self;
        action = #selector(performClickAction)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func performClickAction() { clicked?() }
}

final class ComparePlaceholder: NSView {
    private let image = CompareStateArtwork(), heading = NSTextField(labelWithString: ""), detail = NSTextField(wrappingLabelWithString: "")
    let button = ComparePrimaryButton(title: "Choose Folder…", clicked: {})
    var secondaryActionWidth: CGFloat = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [image, heading, detail, button] { addSubview(view) }
        heading.font = .systemFont(ofSize: 15, weight: .semibold); heading.alignment = .center
        detail.font = .systemFont(ofSize: 12); detail.textColor = Theme.windowTextInactive; detail.alignment = .center
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    var onDrop: ((URL) -> Void)?
    func performPrimaryAction() { button.performClick(nil) }
    func configure(symbol: String, title: String, detail: String, button: String, action: @escaping () -> Void) {
        image.symbol = symbol; image.needsDisplay = true
        heading.stringValue = title; self.detail.stringValue = detail; self.button.title = button; self.button.clicked = action; needsLayout = true
    }
    override func layout() {
        super.layout()
        let folder = image.symbol.contains("folder"), size: CGFloat = folder ? 64 : 48
        image.frame = CGRect(x: (bounds.width - size) / 2, y: 0, width: size, height: size)
        heading.frame = CGRect(x: 0, y: size + 12, width: bounds.width, height: 24)
        detail.isHidden = detail.stringValue.isEmpty
        detail.frame = CGRect(x: 5, y: heading.frame.maxY + 4, width: bounds.width - 10, height: detail.isHidden ? 0 : (folder ? 36 : 18))
        button.frame = CGRect(x: (bounds.width - 180 - secondaryActionWidth) / 2, y: detail.frame.maxY + 14, width: 180, height: 30)
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
    private var detailsHeaders: [DetailsHeaderView] = []
    func attachDetails(_ headers: [DetailsHeaderView]) {
        detailsHeaders = headers
        headers.forEach {
            addSubview($0); $0.isHidden = false
        }
        needsLayout = true; needsDisplay = true
    }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let width = (bounds.width - gutterWidth) / 2
        for (index, header) in detailsHeaders.enumerated() {
            header.frame = CGRect(x: index == 0 ? 0 : width + gutterWidth, y: 0, width: width, height: bounds.height)
            header.needsDisplay = true
        }
    }
    override func draw(_ dirty: NSRect) {
        Theme.windowBackground.setFill(); bounds.fill()
    }
}

final class CompareFocusButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

final class CompareFocusSlider: NSSlider {
    override var acceptsFirstResponder: Bool { true }
}

final class ComparePrimaryButton: CompareActionButton {
    override var acceptsFirstResponder: Bool { true }
    var isPrimary = true { didSet { needsDisplay = true } }
    override func draw(_ dirty: NSRect) {
        (isPrimary ? Theme.accent : Theme.windowText).withAlphaComponent(isEnabled ? (isPrimary ? 1 : 0.08) : 0.04).setFill()
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        capsule.fill()
        if !isPrimary { Theme.frame.setStroke(); capsule.lineWidth = 1; capsule.stroke() }
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState(); NSFocusRingPlacement.only.set(); capsule.fill(); NSGraphicsContext.restoreGraphicsState()
        }
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let foreground = isPrimary ? (Theme.increasedContrast ? Theme.selectionText : NSColor.white) : Theme.windowText
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        var labelRect = CGRect(x: 4, y: (bounds.height - 16) / 2, width: bounds.width - 8, height: 18)
        if let image {
            let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
            let start = (bounds.width - textWidth - 18) / 2
            image.withSymbolConfiguration(.init(paletteColors: [foreground]))?.draw(
                in: CGRect(x: start, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: isFlipped, hints: nil)
            labelRect.origin.x = start + 18; labelRect.size.width = textWidth
        }
        (title as NSString).draw(
            in: labelRect,
            withAttributes: [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: style,
            ])
    }
}

private final class CompareStateArtwork: NSView {
    var symbol = ""
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        if symbol == "checkmark.circle" {
            Theme.compareOnly.withAlphaComponent(effectiveAppearance.isDark ? 0.2 : 0.16).setFill(); NSBezierPath(ovalIn: bounds).fill()
            let check = NSBezierPath(); check.move(to: CGPoint(x: 14, y: 25)); check.line(to: CGPoint(x: 21, y: 32));
            check.line(to: CGPoint(x: 34, y: 17)); check.lineWidth = 2.5; check.lineCapStyle = .round; check.lineJoinStyle = .round;
            Theme.compareOnly.setStroke(); check.stroke()
        } else if symbol.contains("folder") {
            let folder = NSBezierPath(); folder.move(to: CGPoint(x: 6, y: 15)); folder.line(to: CGPoint(x: 26, y: 15));
            folder.line(to: CGPoint(x: 33, y: 22)); folder.line(to: CGPoint(x: 58, y: 22)); folder.line(to: CGPoint(x: 58, y: 54));
            folder.line(to: CGPoint(x: 6, y: 54)); folder.close(); folder.lineWidth = 1.5; folder.lineJoinStyle = .round;
            folder.setLineDash([4, 3], count: 2, phase: 0); Theme.windowText.withAlphaComponent(Theme.increasedContrast ? 0.6 : 0.25).setStroke();
            folder.stroke()
        } else {
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.draw(in: bounds)
        }
    }
}

final class CompareArcSpinner: NSView {
    override init(frame: CGRect) { super.init(frame: frame); setAccessibilityRole(.progressIndicator); setAccessibilityLabel("Comparing") }
    required init?(coder: NSCoder) { fatalError() }
    func startAnimation(_ sender: Any?) { needsDisplay = true }
    func stopAnimation(_ sender: Any?) { needsDisplay = true }
    override func draw(_ dirty: NSRect) {
        let angle =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0 : CGFloat(CACurrentMediaTime().truncatingRemainder(dividingBy: 1.2) / 1.2 * 360)
        let arc = NSBezierPath(); arc.lineWidth = 1.5; arc.lineCapStyle = .round;
        arc.appendArc(
            withCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(2, min(bounds.width, bounds.height) / 2 - 1), startAngle: angle,
            endAngle: angle + 270);
        Theme.accent.setStroke(); arc.stroke()
    }
}

private final class CompareProgressLine: NSView {
    var isIndeterminate = false { didSet { needsDisplay = true } }
    var doubleValue = 0.0 { didSet { needsDisplay = true } }
    var onFrame: (() -> Void)?
    private var timer: Timer?
    func startAnimation(_ sender: Any?) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            self?.needsDisplay = true; self?.onFrame?()
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stopAnimation(_ sender: Any?) { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
    override func draw(_ dirty: NSRect) {
        Theme.accent.setFill()
        if isIndeterminate {
            let phase =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.5 : CACurrentMediaTime().truncatingRemainder(dividingBy: 1.2) / 1.2
            CGRect(x: CGFloat(phase * 1.3 - 0.3) * bounds.width, y: 0, width: bounds.width * 0.3, height: 2).intersection(bounds).fill()
        } else {
            CGRect(x: 0, y: 0, width: bounds.width * min(1, max(0, doubleValue)), height: 2).fill()
        }
    }
}
