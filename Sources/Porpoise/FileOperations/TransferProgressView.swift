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
    private let speed = NSTextField(labelWithString: "")
    private let remaining = NSTextField(labelWithString: "")
    private let controls = NSStackView()
    private let disclosure = NSButton(title: "Show Speed", target: nil, action: nil)
    let speedHistory = SpeedHistoryView(frame: .zero)
    private weak var activity: Activity?
    private weak var parentWindow: NSWindow?
    private var actions: [ActivityAction] = []
    private(set) var isExpanded = false
    var onHeightChanged: (() -> Void)?
    var preferredHeight: CGFloat { isExpanded ? 278 : 168 }
    override var isFlipped: Bool { true }

    init(window: NSWindow?) {
        parentWindow = window
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.small
        layer?.borderWidth = 1
        title.font = Tokens.font(.headline)
        counts.font = Tokens.font(.body, digits: true)
        current.font = Tokens.font(.footnote)
        amount.font = Tokens.font(.footnote, digits: true)
        speed.font = Tokens.font(.footnote, digits: true)
        remaining.font = Tokens.font(.footnote)
        for label in [title, counts, current, amount, speed, remaining] {
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
        speed.alignment = .right
        remaining.alignment = .right
        controls.orientation = .horizontal
        controls.spacing = Tokens.Space.s
        disclosure.bezelStyle = .inline
        disclosure.controlSize = .small
        disclosure.target = self; disclosure.action = #selector(toggleSpeed)
        disclosure.setAccessibilityLabel("Show transfer speed graph")
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
            layer?.backgroundColor = Theme.viewBackground.cgColor
            layer?.borderColor = Theme.separator.cgColor
            title.textColor = Theme.viewText
            counts.textColor = Theme.viewText
            for label in [current, amount, speed, remaining] { label.textColor = Theme.viewTextInactive }
        }
        speedHistory.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 24)
        title.frame = CGRect(x: 12, y: 10, width: width, height: 18)
        counts.frame = CGRect(x: 12, y: 34, width: width, height: 18)
        current.frame = CGRect(x: 12, y: 56, width: width, height: 16)
        progress.frame = CGRect(x: 12, y: 78, width: width, height: 10)
        amount.frame = CGRect(x: 12, y: 96, width: width * 0.62, height: 16)
        speed.frame = CGRect(x: 12 + width * 0.62, y: 96, width: width * 0.38, height: 16)
        remaining.frame = CGRect(x: 12, y: 115, width: width, height: 16)
        let controlsSize = controls.fittingSize
        controls.frame = CGRect(x: max(12, bounds.width - 12 - controlsSize.width), y: 136, width: controlsSize.width, height: 24)
        disclosure.sizeToFit()
        disclosure.frame = CGRect(x: 12, y: 138, width: disclosure.frame.width, height: 20)
        speedHistory.frame = CGRect(x: 12, y: 172, width: width, height: 96)
    }

    @objc private func toggleSpeed() {
        isExpanded.toggle()
        speedHistory.isHidden = !isExpanded
        disclosure.title = isExpanded ? "Hide Speed" : "Show Speed"
        disclosure.setAccessibilityLabel(isExpanded ? "Hide transfer speed graph" : "Show transfer speed graph")
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
            return "\(FileFormat.count(done)) of \(FileFormat.count(total)) \(name)"
        }
        let knownCounts = summary.totalFiles != nil && summary.totalFolders != nil
        counts.stringValue =
            (knownCounts ? "Processed " : "") + count(summary.completedFiles, summary.totalFiles, "files") + " · "
            + count(summary.completedFolders, summary.totalFolders, "folders")
        if activity.kind == .move, activity.state == .completed, !knownCounts { counts.stringValue = "Moved · contents not counted" }
        current.stringValue =
            activity.state.isEnded ? presentation.detailLine : summary.currentName.isEmpty ? activity.statusText : summary.currentName
        current.toolTip = activity.state.isEnded ? activity.statusText : summary.currentName
        current.textColor = presentation.hasFailures ? Theme.transferDanger : Theme.viewTextInactive
        progress.fraction = activity.state == .completed && !presentation.hasFailures ? 1 : summary.fraction
        progress.isIndeterminate = presentation.isIndeterminate
        progress.alphaValue = presentation.isPaused ? 0.5 : 1
        amount.stringValue =
            summary.totalBytes > 0
            ? "\(FileFormat.size(summary.doneBytes)) of \(FileFormat.size(summary.totalBytes))" : FileFormat.size(summary.doneBytes)
        speed.stringValue = summary.speedText ?? "—"
        remaining.stringValue =
            activity.state == .paused
            ? "Paused" : activity.state.isEnded ? activity.state.rawValue.capitalized : summary.timeLeftText ?? activity.statusText
        remaining.toolTip = remaining.stringValue
        speedHistory.samples = summary.speedSamples
        setActions(presentation.actions)
        setAccessibilityLabel(activity.title + ". " + counts.stringValue + ". " + current.stringValue)
        needsLayout = true
    }

    private func setActions(_ desired: [ActivityAction]) {
        guard desired != actions else { return }
        actions = desired
        controls.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let primary = desired.filter { [.pause, .resume, .cancel, .retry].contains($0) }
        let secondary = desired.filter { !primary.contains($0) }
        for action in primary {
            let label: String
            switch action {
            case .pause: label = "Pause"
            case .resume: label = "Resume"
            case .cancel: label = "Stop"
            default: label = "Retry"
            }
            let button = ClosureButton(title: label) { [weak self] _ in self?.run(action) }
            button.controlSize = .small; button.bezelStyle = .rounded; button.toolTip = action.help
            button.setAccessibilityLabel(action.help); controls.addArrangedSubview(button)
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
