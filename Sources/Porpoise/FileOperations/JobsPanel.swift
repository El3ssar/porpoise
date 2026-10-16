import AppKit
import PorpoiseCore
import PorpoiseServices

/// Toolbar-local transfer progress. Each window keeps its own popover; Activity keeps the history.
final class TransferToolbarButton: NSButton {
    var visibilityChanged: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private let popover = NSPopover()
    private var rows: [UUID: TransferPopoverRow] = [:]
    private var shownIDs: [UUID] = []
    private var jobs: [Activity] = []
    private var fraction = 0.0
    private var ended = false
    private var failed = false
    private var dismissedFailure: Set<UUID> = []
    private var didShowAttention: Set<UUID> = []
    private var lastRefresh = Date.distantPast
    private var shownStates = ""
    private var shownProgress = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; title = ""; isHidden = true
        target = self; action = #selector(showTransfers)
        toolTip = "File operations"
        setAccessibilityLabel("File operations")
        popover.behavior = Settings.isTesting ? .applicationDefined : .transient
        observer = NotificationCenter.default.addObserver(forName: FileOperationsController.activityChanged, object: nil, queue: .main) {
            [weak self] _ in self?.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; timer?.invalidate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }

    private func refresh() {
        guard let window else { return }
        let now = Date()
        let all = FileOperationsController.shared.activities.filter { $0.originWindow === window }
        let states = all.map { $0.id.uuidString + $0.state.rawValue }.joined(separator: "|")
        guard states != shownStates || now.timeIntervalSince(lastRefresh) >= 0.25 else { return }
        shownStates = states; lastRefresh = now
        jobs = all.filter { a in
            if a.state.isActive || a.state == .queued { return true }
            if !a.errors.isEmpty && !dismissedFailure.contains(a.id) { return true }
            return a.finishedAt.map { now.timeIntervalSince($0) < 3 } ?? false
        }
        let active = jobs.filter { $0.state.isActive || $0.state == .queued }
        let visible = !jobs.isEmpty && jobs.contains { now.timeIntervalSince($0.startedAt ?? $0.queuedAt) >= 0.6 }
        if visible != !isHidden { isHidden = !visible; visibilityChanged?() }
        ended = active.isEmpty
        failed = jobs.contains { !$0.errors.isEmpty }
        let total = active.reduce(Int64(0)) { $0 + ($1.progress?.totalBytes ?? 0) }
        fraction =
            total > 0
            ? Double(active.reduce(Int64(0)) { $0 + ($1.progress?.doneBytes ?? 0) }) / Double(total)
            : active.isEmpty ? 1 : active.reduce(0) { $0 + $1.fraction } / Double(active.count)
        let estimate = active.first?.rate.timeLeftText ?? (failed ? "Needs attention" : "Finished")
        let label = "File operations, \(Int(fraction * 100)) percent, \(estimate)"
        let progress = "\(Int(fraction * 1000))|\(ended)|\(failed)|\(jobs.allSatisfy { $0.state == .paused })|\(label)"
        if progress != shownProgress {
            shownProgress = progress; setAccessibilityLabel(label); needsDisplay = true
        }
        if popover.isShown { updatePopover() }
        if let attention = jobs.first(where: { ($0.state == .waiting || !$0.errors.isEmpty) && !didShowAttention.contains($0.id) }), visible,
            window.isKeyWindow, window.attachedSheet == nil
        {
            didShowAttention.insert(attention.id)
            showTransfers()
        }
        if timer == nil && !jobs.isEmpty {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        } else if jobs.isEmpty {
            timer?.invalidate(); timer = nil; popover.performClose(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if ended {
            let image = NSImage(
                systemSymbolName: failed ? "exclamationmark.circle.fill" : "checkmark",
                accessibilityDescription: failed ? "Needs attention" : "Finished")
            (failed ? Theme.compareDanger : Theme.compareOnly).set()
            image?.withSymbolConfiguration(.init(paletteColors: failed ? [.white, Theme.compareDanger] : [Theme.compareOnly]))?.draw(
                in: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18))
        } else {
            let track = NSBezierPath(ovalIn: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))
            track.lineWidth = 2.5; Theme.windowText.withAlphaComponent(0.14).setStroke(); track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 11, startAngle: 90, endAngle: 90 - CGFloat(max(0.025, min(1, fraction))) * 360, clockwise: true)
            arc.lineWidth = 2.5; arc.lineCapStyle = .round; Theme.activeText.setStroke(); arc.stroke()
            let image = NSImage(
                systemSymbolName: jobs.allSatisfy { $0.state == .paused } ? "pause.fill" : "arrow.down", accessibilityDescription: nil)
            image?.withSymbolConfiguration(.init(paletteColors: [Theme.windowText]))?.draw(
                in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
        }
    }

    @objc func showTransfers() {
        if popover.isShown { popover.performClose(nil); return }
        guard !jobs.isEmpty else { ActivityWindowController.shared.show(); return }
        updatePopover()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        popover.contentViewController?.view.window?.title = "Transfers"
        dismissedFailure.formUnion(jobs.filter { !$0.errors.isEmpty }.map(\.id))
    }
    private func updatePopover() {
        let shown = Array(jobs.suffix(6).reversed())
        let ids = shown.map(\.id)
        if ids == shownIDs, popover.contentViewController != nil {
            for activity in shown { rows[activity.id]?.update(activity) }
            return
        }
        shownIDs = ids
        let content = popover.contentViewController ?? NSViewController()
        let view = content.viewIfLoaded ?? TransferPopoverContent()
        content.view = view
        view.setFrameSize(CGSize(width: 430, height: CGFloat(shown.count) * 64 + 42))
        view.subviews.forEach { $0.removeFromSuperview() }
        rows = rows.filter { key, _ in shown.contains { $0.id == key } }
        for (index, activity) in shown.enumerated() {
            let row = rows[activity.id] ?? TransferPopoverRow()
            rows[activity.id] = row
            row.update(activity)
            row.frame = CGRect(x: 0, y: view.bounds.height - CGFloat(index + 1) * 64, width: 430, height: 64)
            view.addSubview(row)
        }
        let all = NSButton(title: "Show All in Activity", target: self, action: #selector(showAll))
        all.isBordered = false; all.contentTintColor = Theme.activeText; all.alignment = .left
        all.frame = CGRect(x: 12, y: 8, width: 320, height: 26); view.addSubview(all)
        let shortcut = NSTextField(labelWithString: "⌥⌘J")
        shortcut.font = .systemFont(ofSize: 11); shortcut.textColor = Theme.windowTextInactive
        shortcut.frame = CGRect(x: 382, y: 12, width: 36, height: 18); view.addSubview(shortcut)
        popover.contentViewController = content
        popover.contentSize = view.frame.size
    }
    @objc private func showAll() { popover.performClose(nil); ActivityWindowController.shared.show() }
}

private final class TransferPopoverRow: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = ActivityProgressView()
    private let percent = NSTextField(labelWithString: "")
    private let pause = NSButton()
    private let stop = NSButton()
    private var activity: Activity?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11); detail.textColor = Theme.windowTextInactive; detail.lineBreakMode = .byTruncatingTail
        for button in [pause, stop] { button.isBordered = false; button.imagePosition = .imageOnly; button.target = self }
        pause.action = #selector(togglePause); stop.action = #selector(stopJob)
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop"); stop.toolTip = "Stop"
        percent.font = .systemFont(ofSize: 10); percent.textColor = Theme.windowTextInactive
        for view in [icon, title, detail, bar, percent, pause, stop] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ activity: Activity) {
        self.activity = activity
        if let item = activity.incomingItem {
            icon.image = Icons.shared.image(for: item, size: 32)
        } else if activity.planJob != nil {
            icon.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync")
        } else {
            icon.image = NSImage(systemSymbolName: activity.sources.count > 1 ? "square.stack.3d.up" : "doc", accessibilityDescription: nil)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.stringValue = activity.title
        var line = (activity.state == .completed ? TransferSummary.text(activity) : activity.statusText).replacingOccurrences(of: " — ", with: " · ")
        if activity.planJob == nil, let progress = activity.progress, progress.phase == .transferring,
            activity.state == .running || activity.state == .paused
        {
            var parts: [String] = []
            if activity.state == .paused { parts.append("Paused") }
            if progress.totalFiles > 1 { parts.append("\(progress.doneFiles) of \(progress.totalFiles)") }
            if progress.totalBytes > 0 { parts.append(Self.amounts(progress.doneBytes, of: progress.totalBytes)) }
            if activity.state == .running {
                if activity.rate.hasSpeedEstimate { parts.append(activity.rate.speedText) }
                parts.append(activity.rate.timeLeftText)
            }
            line = parts.joined(separator: " · ")
        }
        detail.stringValue = line
        percent.stringValue = "\(Int(activity.fraction * 100))%"
        percent.isHidden = activity.state.isEnded || (activity.planJob == nil && activity.progress?.phase == .preparing)
        toolTip = activity.planProgress?.currentTitle ?? activity.progress?.currentName
        bar.fraction = activity.fraction
        bar.isIndeterminate = (activity.planJob == nil && activity.progress?.phase == .preparing) || activity.state == .queued
        bar.alphaValue = activity.state == .paused ? 0.4 : 1
        bar.isHidden = activity.state.isEnded
        pause.isHidden = !(activity.canPause || activity.state == .cancelled || !activity.errors.isEmpty)
        pause.image = NSImage(
            systemSymbolName: !activity.errors.isEmpty
                ? "exclamationmark.bubble" : activity.state == .paused || activity.state == .cancelled ? "play.fill" : "pause.fill",
            accessibilityDescription: !activity.errors.isEmpty
                ? "Show failures" : activity.state == .paused || activity.state == .cancelled ? "Resume" : "Pause")
        stop.isHidden = activity.state.isEnded
        setAccessibilityLabel(activity.title + ". " + activity.statusText)
    }
    /// Transfer presentation uses decimal units and the same locale/precision as TransferRate.speedText.
    private static func amounts(_ done: Int64, of total: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scale = 1.0, index = 0
        while Double(total) / scale >= 1000 && index < units.count - 1 { scale *= 1000; index += 1 }
        func number(_ value: Int64) -> String {
            let scaled = Double(value) / scale
            return scaled.formatted(.number.precision(.fractionLength(scaled < 10 && index > 0 ? 1 : 0)))
        }
        return "\(number(done)) of \(number(total)) \(units[index])"
    }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 12, y: 19, width: 32, height: 32)
        title.frame = CGRect(x: 54, y: 40, width: 310, height: 17)
        bar.frame = CGRect(x: 54, y: 29, width: 272, height: 4)
        percent.frame = CGRect(x: 334, y: 23, width: 34, height: 16)
        detail.frame = CGRect(x: 54, y: 6, width: 364, height: 16)
        pause.frame = CGRect(x: 370, y: 34, width: 24, height: 24)
        stop.frame = CGRect(x: 396, y: 34, width: 24, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill(); CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
    @objc private func togglePause() {
        guard let activity else { return }
        let controller = FileOperationsController.shared
        if !activity.errors.isEmpty { controller.ui?.showTransferErrors(activity, window: activity.originWindow); return }
        if activity.state == .paused || activity.state == .cancelled { controller.resume(activity) } else { controller.pause(activity) }
    }
    @objc private func stopJob() { if let activity { FileOperationsController.shared.cancel(activity) } }
}

/// Owns only the Dock aggregate. Window toolbars observe Activity directly.
final class JobsPanel {
    private var timer: Timer?
    func add(_ job: FileJob) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func update(_ job: FileJob, _ progress: JobProgress) {}
    func finish(_ job: FileJob) { refresh() }
    private func refresh() {
        let jobs = FileOperationsController.shared.activities.filter { $0.state.isActive }
        guard !jobs.isEmpty else {
            timer?.invalidate(); timer = nil; NSApp.dockTile.contentView = nil; NSApp.dockTile.display(); return
        }
        // Progress updates never open or raise Activity. A pending conflict sheet keeps keyboard/mouse focus.
        guard jobs.contains(where: { Date().timeIntervalSince($0.startedAt ?? Date()) > 2 }) else { return }
        let view = NSApp.dockTile.contentView as? TransferDockView ?? TransferDockView(frame: CGRect(origin: .zero, size: NSApp.dockTile.size))
        let total = jobs.reduce(Int64(0)) { $0 + ($1.progress?.totalBytes ?? 0) }
        view.fraction =
            total > 0
            ? Double(jobs.reduce(Int64(0)) { $0 + ($1.progress?.doneBytes ?? 0) }) / Double(total)
            : jobs.reduce(0) { $0 + $1.fraction } / Double(jobs.count)
        NSApp.dockTile.contentView = view; NSApp.dockTile.display()
    }
}
private final class TransferDockView: NSView {
    var fraction = 0.0
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let track = CGRect(x: bounds.width * 0.13, y: bounds.height * 0.08, width: bounds.width * 0.74, height: 8)
        NSColor.black.withAlphaComponent(0.5).setFill(); NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        NSColor.controlAccentColor.setFill();
        NSBezierPath(
            roundedRect: CGRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, fraction)), height: track.height), xRadius: 4,
            yRadius: 4
        ).fill()
    }
}

private final class TransferPopoverContent: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .popover; blendingMode = .withinWindow; state = .active
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One result sentence shared by the toolbar popover and the originating window's status bar.
enum TransferSummary {
    static func text(_ activity: Activity) -> String {
        guard activity.planJob == nil, activity.state == .completed, activity.kind == .copy || activity.kind == .move,
            let progress = activity.progress
        else {
            return activity.statusText
        }
        let count = progress.copiedItems
        var parts = [
            "\(activity.kind == .move ? "Moved" : "Copied") \(FileFormat.itemCount(count))"
                + (activity.destination.map { " to " + $0.lastPathComponent } ?? "")
        ]
        if !activity.errors.isEmpty { parts.append("\(activity.errors.count) couldn’t be \(activity.kind == .move ? "moved" : "copied")") }
        if progress.replacedItems > 0 { parts.append("replaced \(progress.replacedItems)") }
        if progress.skippedIdenticalItems > 0 {
            parts.append("skipped \(progress.skippedIdenticalItems) identical (\(activity.comparisonMethodTitle))")
        }
        return parts.joined(separator: " · ")
    }
}
