import AppKit
import PorpoiseCore
import PorpoiseServices

/// One compact operation, not a file table. Expanding Details reveals only measured throughput over time.
final class TransferProgressView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private let current = NSTextField(labelWithString: "")
    private let progress = ThinProgressView(thickness: 6, label: "Transfer progress")
    private let amount = NSTextField(labelWithString: "")
    private let percentage = NSTextField(labelWithString: "")
    private let remaining = NSTextField(labelWithString: "")
    private let controls = NSStackView()
    private let disclosure = NSButton(title: "Details", target: nil, action: nil)
    let speedHistory = SpeedHistoryView(frame: .zero)
    private weak var activity: Activity?
    private weak var parentWindow: NSWindow?
    private var actions: [ActivityAction] = []
    private(set) var isExpanded = false
    var onHeightChanged: (() -> Void)?
    var onDismiss: (() -> Void)?
    var preferredHeight: CGFloat { isExpanded ? 268 : 164 }
    override var isFlipped: Bool { true }

    init(window: NSWindow?) {
        parentWindow = window
        super.init(frame: .zero)
        wantsLayer = true
        title.font = Tokens.font(.headline)
        counts.font = Tokens.font(.body, digits: true)
        current.font = Tokens.font(.callout)
        amount.font = Tokens.font(.footnote, digits: true)
        percentage.font = Tokens.font(.footnote, digits: true)
        remaining.font = Tokens.font(.footnote)
        for label in [title, counts, current, amount, percentage, remaining] {
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
        percentage.alignment = .right
        remaining.alignment = .right
        controls.orientation = .horizontal
        controls.spacing = Tokens.Space.s
        disclosure.bezelStyle = .inline
        disclosure.controlSize = .small
        disclosure.target = self; disclosure.action = #selector(toggleSpeed)
        disclosure.setAccessibilityLabel("Show transfer details")
        disclosure.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        disclosure.imagePosition = .imageLeading
        disclosure.toolTip = "Show transfer speed and timing"
        for view in [progress, controls, disclosure, speedHistory] as [NSView] { addSubview(view) }
        speedHistory.isHidden = true
        Theme.whenChanged(self) { [weak self] in self?.applyTheme() }
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.windowBackground.cgColor
            title.textColor = Theme.viewText
            counts.textColor = Theme.viewTextInactive
            current.textColor = Theme.viewText
            for label in [amount, percentage, remaining] { label.textColor = Theme.viewTextInactive }
        }
        speedHistory.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        title.frame = CGRect(x: 0, y: 0, width: width, height: 18)
        current.frame = CGRect(x: 0, y: 26, width: width, height: 18)
        counts.frame = CGRect(x: 0, y: 52, width: width, height: 18)
        progress.frame = CGRect(x: 0, y: 82, width: max(0, width - 48), height: 8)
        percentage.frame = CGRect(x: max(0, width - 44), y: 76, width: 44, height: 18)
        speedHistory.frame = CGRect(x: 0, y: 78, width: width, height: 116)
        let metricsY: CGFloat = isExpanded ? 208 : 104
        amount.frame = CGRect(x: 0, y: metricsY, width: width * 0.42, height: 18)
        remaining.frame = CGRect(x: width * 0.42, y: metricsY, width: width * 0.58, height: 18)
        let controlsSize = controls.fittingSize
        controls.frame = CGRect(x: max(0, width - controlsSize.width), y: metricsY + 32, width: controlsSize.width, height: 24)
        disclosure.sizeToFit()
        disclosure.frame = CGRect(x: 0, y: metricsY + 34, width: disclosure.frame.width, height: 20)
    }

    @objc private func toggleSpeed() {
        isExpanded.toggle()
        speedHistory.isHidden = !isExpanded
        progress.isHidden = isExpanded
        percentage.isHidden = isExpanded || progress.isIndeterminate
        disclosure.image = NSImage(systemSymbolName: isExpanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        disclosure.setAccessibilityLabel(isExpanded ? "Hide transfer details" : "Show transfer details")
        disclosure.toolTip = isExpanded ? "Hide transfer speed and timing" : "Show transfer speed and timing"
        disclosure.setAccessibilityValue(isExpanded ? 1 : 0)
        needsLayout = true
        onHeightChanged?()
    }

    func update(_ activity: Activity) {
        self.activity = activity
        let summary = activity.transferSummary
        let presentation = ActivityPresentation(activity)
        title.stringValue = activity.title
        title.toolTip = activity.title
        func count(_ done: Int?, _ total: Int?, _ name: String) -> String {
            guard let done, let total else { return "\(name.capitalized): " + (activity.state.isEnded ? "not counted" : "counting…") }
            let noun = total == 1 ? String(name.dropLast()) : name
            return "\(FileFormat.count(done)) of \(FileFormat.count(total)) \(noun)"
        }
        let knownCounts = summary.totalFiles != nil && summary.totalFolders != nil
        counts.stringValue =
            (knownCounts ? "Processed " : "") + count(summary.completedFiles, summary.totalFiles, "files") + " · "
            + count(summary.completedFolders, summary.totalFolders, "folders")
        if activity.kind == .move, activity.state == .completed, !knownCounts { counts.stringValue = "Moved · contents not counted" }
        current.stringValue =
            activity.state.isEnded ? presentation.detailLine : summary.currentName.isEmpty ? activity.statusText : summary.currentName
        current.toolTip = activity.state.isEnded ? activity.statusText : summary.currentName
        current.textColor = presentation.hasFailures ? Theme.transferDanger : Theme.viewText
        progress.fraction = activity.state == .completed && !presentation.hasFailures ? 1 : summary.fraction
        progress.isIndeterminate = presentation.isIndeterminate
        progress.alphaValue = presentation.isPaused ? 0.5 : 1
        percentage.isHidden = isExpanded || presentation.isIndeterminate
        amount.stringValue =
            summary.totalBytes > 0
            ? "\(FileFormat.size(summary.doneBytes)) of \(FileFormat.size(summary.totalBytes))" : FileFormat.size(summary.doneBytes)
        percentage.stringValue = "\(Int((summary.fraction * 100).rounded()))%"
        remaining.stringValue =
            activity.state == .paused
            ? "Paused"
            : activity.state.isEnded
                ? activity.state.rawValue.capitalized
                : [summary.speedText, summary.timeLeftText].compactMap { $0 }.joined(separator: " · ")
        if remaining.stringValue.isEmpty { remaining.stringValue = activity.statusText }
        remaining.toolTip = remaining.stringValue
        speedHistory.currentSpeed = summary.bytesPerSecond
        // Skipped or reused bytes advance completion but are not transferred throughput.
        speedHistory.averageSpeed = summary.elapsed > 0 ? Double(activity.progress?.transferredBytes ?? 0) / summary.elapsed : nil
        speedHistory.samples = summary.speedSamples
        let hasFinishedWithoutSamples = activity.state.isEnded && summary.speedSamples.count < 2
        disclosure.isHidden = hasFinishedWithoutSamples
        if hasFinishedWithoutSamples, isExpanded {
            isExpanded = false
            speedHistory.isHidden = true
            progress.isHidden = false; percentage.isHidden = false
            disclosure.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            disclosure.setAccessibilityLabel("Show transfer details")
            disclosure.setAccessibilityValue(0)
            onHeightChanged?()
        }
        var actions =
            presentation.hasFailures && !presentation.actions.contains(.failures) ? [.failures] + presentation.actions : presentation.actions
        if activity.state == .interrupted, !actions.contains(.retry) { actions.insert(.retry, at: 0) }
        setActions(actions, allowsDismissal: activity.state.isEnded)
        setAccessibilityLabel(activity.title + ". " + counts.stringValue + ". " + current.stringValue)
        needsLayout = true
    }

    private var offeredDismissal = false
    private func setActions(_ desired: [ActivityAction], allowsDismissal: Bool) {
        guard desired != actions || offeredDismissal != allowsDismissal else { return }
        offeredDismissal = allowsDismissal
        actions = desired
        controls.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let primary = desired.filter { [.pause, .resume, .cancel, .retry, .failures].contains($0) }
        let secondary = desired.filter { !primary.contains($0) }
        for action in primary {
            let label: String
            switch action {
            case .pause: label = "Pause"
            case .resume: label = "Resume"
            case .cancel: label = "Cancel"
            case .failures: label = "Show Errors"
            default: label = "Retry"
            }
            let button = ClosureButton(title: label) { [weak self] _ in self?.run(action) }
            button.controlSize = .small; button.bezelStyle = .rounded
            button.toolTip = action == .cancel ? "Cancel this transfer" : action.help
            button.setAccessibilityLabel(label); controls.addArrangedSubview(button)
        }
        if !secondary.isEmpty {
            let more = NSPopUpButton(frame: .zero, pullsDown: true)
            more.controlSize = .small
            more.addItem(withTitle: "More")
            more.setAccessibilityLabel("More transfer actions")
            for action in secondary {
                let item = NSMenuItem(title: action.help, action: #selector(runMenuAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = ActivityAction.allCases.firstIndex(of: action) ?? 0
                more.menu?.addItem(item)
            }
            controls.addArrangedSubview(more)
        }
        if allowsDismissal {
            let dismiss = ClosureButton(title: "Dismiss") { [weak self] _ in self?.onDismiss?() }
            dismiss.controlSize = .small; dismiss.bezelStyle = .rounded
            dismiss.toolTip = "Dismiss this transfer without changing your files"
            controls.addArrangedSubview(dismiss)
        }
    }

    @objc private func runMenuAction(_ item: NSMenuItem) {
        guard ActivityAction.allCases.indices.contains(item.tag) else { return }
        run(ActivityAction.allCases[item.tag])
    }

    private func run(_ action: ActivityAction) {
        guard let activity else { return }
        let controller = FileOperationsController.shared
        switch action {
        case .pause: controller.pause(activity)
        case .resume: controller.resume(activity)
        case .cancel: controller.cancel(activity)
        case .earlier: controller.move(activity, by: -1)
        case .later: controller.move(activity, by: 1)
        case .retry: controller.retry(activity, window: parentWindow)
        case .failures: controller.ui?.showTransferErrors(activity, window: parentWindow)
        case .reveal: if let destination = activity.destination { (NSApp.delegate as? AppDelegate)?.newWindow(at: destination) }
        }
    }
}
