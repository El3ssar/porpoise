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
    let sync = CompareSyncButton(title: "Sync…", target: nil, action: nil)
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
    private var progressTicker: Timer?
    private let pause = ComparePrimaryButton(title: "Pause", clicked: {})
    private let jobLine = CompareProgressLine()

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
        jobWash.wantsLayer = true; bar.addSubview(jobWash)
        for child in [sync, close, progress, progressLabel, stop, pause, showJob, jobSymbol, jobLine] { bar.addSubview(child) }
        showJob.isBordered = false; showJob.font = .systemFont(ofSize: 12); showJob.contentTintColor = Theme.accent
        showJob.target = self; showJob.action = #selector(showJobPressed); showJob.isHidden = true; jobSymbol.isHidden = true
        for child in [method, methodSeparator, summary, sizes, smallZoom, zoom, largeZoom] { footer.addSubview(child) }
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
        popover?.close(); popover = nil; currentActivity = nil; completedActivity = nil; jobMetadata = [:]; reviewJob = nil
        activityPaintTimer?.invalidate(); activityPaintTimer = nil; lastActivityPaint = 0; lastActivityState = nil; laidOutActivityState = nil
        activityNotificationCount = 0; activityPaintCount = 0
        self.model = model; document.model = model
        document.selectedPath = nil; document.finishedPaths = []; document.failedPaths = []; document.hoverIndex = nil
        document.replaceRows([], indices: [:]); lastRowsVersion = -1
        scroll.contentView.scroll(to: .zero)
        model.onChange = { [weak self] in self?.update() }; update()
    }
    deinit { progressTicker?.invalidate(); activityPaintTimer?.invalidate() }
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
        let stopWidth = max(68, stop.intrinsicContentSize.width + 24), pauseWidth = max(80, pause.intrinsicContentSize.width + 24)
        let trailing: CGFloat = close.isHidden ? 12 : 40
        stop.frame = CGRect(x: width - trailing - stopWidth, y: 3, width: stopWidth, height: 30)
        pause.frame = CGRect(x: stop.frame.minX - 8 - pauseWidth, y: 3, width: pauseWidth, height: 30)
        if !stop.isHidden { progressLabel.frame.size.width = max(50, (pause.isHidden ? stop.frame.minX : pause.frame.minX) - 48) }
        jobLine.frame = CGRect(x: 0, y: 0, width: width, height: 2)
        jobWash.frame = bar.bounds; jobSymbol.frame = CGRect(x: 11, y: 10, width: 16, height: 16)
        let completedJob = currentActivity?.state == .completed || reviewJob?.state == .completed
        showJob.frame = CGRect(x: completedJob ? width - 164 : stop.frame.minX - 60, y: 6, width: completedJob ? 130 : 44, height: 24)
        if !showJob.isHidden { progressLabel.frame.size.width = max(50, showJob.frame.minX - 48) }
        method.frame = CGRect(x: 6, y: 2, width: 140, height: 24)
        methodSeparator.frame = CGRect(x: 148, y: 6, width: 1, height: 16)
        summary.frame = CGRect(x: 160, y: 7, width: max(50, width - (width < 780 ? 320 : 515)), height: 17)
        sizes.isHidden = width < 780
        sizes.frame = CGRect(x: width - 360, y: 7, width: 200, height: 17)
        smallZoom.frame = CGRect(x: width - 150, y: 4, width: 20, height: 20)
        zoom.frame = CGRect(x: width - 130, y: 7, width: 106, height: 16)
        largeZoom.frame = CGRect(x: width - 24, y: 4, width: 20, height: 20)
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
            progress.startAnimation(nil)
            let count = (model.comparison?.rows.count ?? 0).formatted(), text = "Comparing… \(count) items"
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
            stop.title = "Stop"; stop.image = nil; progressLabel.textColor = Theme.windowTextInactive
        }
        header.needsDisplay = true
        let counts = model.outline?.counts ?? [:]
        let differences = [CompareFilter.onlyLeft, .onlyRight, .changed].reduce(0) { $0 + (counts[$1.rawValue] ?? 0) }
        let elapsed = model.elapsed < 0.1 ? "<0.1 s" : String(format: "%.1f s", model.elapsed)
        let differenceSummary = differences == 0 ? "no differences" : "\(differences.formatted()) differences"
        summary.stringValue =
            model.error
            ?? "\((model.comparison?.rows.count ?? 0).formatted()) items · \(differenceSummary) · \(elapsed)"
        if model.loading {
            summary.stringValue =
                "Reading \(model.options.method == .content ? "contents" : "folders")… \((model.comparison?.rows.count ?? 0).formatted()) items"
        }
        summary.textColor = model.error == nil ? Theme.windowTextInactive : Theme.compareDanger
        summary.toolTip = "Compared by \(Self.methodTitle(model.options.method).lowercased()) · \(summary.stringValue)"
        sizes.stringValue =
            "\(model.names.0) \(FileFormat.size(model.outline?.totalBytes[.left] ?? 0)) · \(model.names.1) \(FileFormat.size(model.outline?.totalBytes[.right] ?? 0))"
        let identical = differences == 0 && model.comparison?.complete == true
        overlay.isHidden = !model.rows.isEmpty || model.loading || (model.comparison == nil && model.error == nil)
        overlay.configure(
            symbol: identical ? "checkmark.circle" : (model.error == nil ? "line.3.horizontal.decrease.circle" : "exclamationmark.triangle"),
            title: model.error != nil
                ? "Couldn't compare these folders"
                : (identical ? "\(model.names.0) and \(model.names.1) are identical" : "No items match these filters."),
            detail: model.error
                ?? (identical
                    ? "\((model.comparison?.rows.count ?? 0).formatted()) items match by \(Self.methodTitle(model.options.method).lowercased().replacingOccurrences(of: "&", with: "and"))."
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
        if currentActivity?.state == .completed || reviewJob?.state == .completed {
            currentActivity = nil; reviewJob = nil; document.finishedPaths = []; update()
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
        if activity.state == .completed, completedActivity != activity.id {
            completedActivity = activity.id; model.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard self?.currentActivity?.id == activity.id, self?.currentActivity?.state == .completed else { return }
                self?.currentActivity = nil; self?.document.finishedPaths = []; self?.update()
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
        pills.forEach { $0.isHidden = true }; sync.isHidden = true
        let paused = job.state == .paused, failed = job.state == .failed, done = job.state == .completed
        progress.isHidden = job.state.isEnded || paused || job.lostConnection; progressLabel.isHidden = false
        let title: String, detail: String, symbol: String?, color: NSColor
        if job.lostConnection {
            title = "Lost connection to \(job.destination)."; detail = "Finished items are kept."; symbol = "exclamationmark.triangle.fill";
            color = Theme.compareChanged
        } else if failed {
            title = "\(max(1, job.errors)) \(job.errors == 1 ? "item couldn’t" : "items couldn’t") be copied."
            detail = job.reason; symbol = "exclamationmark.circle.fill"; color = Theme.compareDanger
        } else if done {
            title = "Synced"; detail = "\(job.copied) copied · \(job.trashed) moved to the Trash · just now"; symbol = "checkmark";
            color = Theme.compareOnly
        } else if paused {
            title = "Paused"; detail = "\(job.completed) of \(job.total) done"; symbol = "pause.fill"; color = Theme.windowTextInactive
        } else {
            title = job.state == .waiting ? "Waiting for your answer" : "Syncing to \(job.destination)"
            detail = "\(job.completed) of \(job.total)"; symbol = nil; color = Theme.accent
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
        close.isHidden = !done
        pause.isHidden = !job.canPause && !job.lostConnection; pause.title = paused || job.lostConnection ? "Resume" : "Pause"
        pause.image = NSImage(systemSymbolName: paused || job.lostConnection ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        pause.imagePosition = .imageLeft; pause.imageHugsTitle = true;
        pause.contentTintColor = paused || job.lostConnection ? Theme.accent : Theme.windowText
        pause.isPrimary = paused || job.lostConnection
        stop.isHidden = job.state.isEnded && !failed; stop.title = failed ? "Try Again" : "Stop"
        stop.image = failed ? nil : NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stop.imagePosition = .imageLeft; stop.imageHugsTitle = true
        showJob.isHidden = !failed && !done; showJob.title = done ? "Show in Activity" : "Show"
        let pair = jobMetadata["pairDescription"] as? String ?? "\(model.names.0) → \(job.destination)"
        summary.stringValue = "\(job.mode) · \(pair)"
        jobLine.isIndeterminate = false
        jobLine.isHidden = job.state.isEnded; jobLine.doubleValue = job.fraction
        jobLine.alphaValue = paused ? 0.4 : 1
        if job.state.isEnded { jobLine.stopAnimation(nil) } else { jobLine.startAnimation(nil) }
        if laidOutActivityState != job.state { laidOutActivityState = job.state; needsLayout = true }
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
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let countWidth = (count.formatted() as NSString).size(withAttributes: [.font: font]).width
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
        let count = count.formatted() as NSString, attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
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
