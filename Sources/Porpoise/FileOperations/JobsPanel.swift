import AppKit
import PorpoiseCore
import PorpoiseServices

/// KDE shows job progress in notifications; here a small floating panel.
final class JobRowView: NSView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let cancel = FlatButton(icon: "process-stop", tooltip: "Cancel")
    weak var job: FileJob?

    init(job: FileJob) {
        self.job = job
        super.init(frame: .zero)
        title.font = Theme.boldFont
        title.textColor = Theme.windowText
        detail.font = Theme.smallFont
        detail.textColor = Theme.windowTextInactive
        detail.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        cancel.onClick = { [weak self] in self?.job?.cancel() }
        for v in [title, detail, bar, cancel] as [NSView] { addSubview(v) }
        title.stringValue = job.kind.verb
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ p: JobProgress) {
        let dest = p.destination.map { " to \($0.lastPathComponent)" } ?? ""
        title.stringValue = "\(p.kind.verb) \(p.totalItems == 1 ? "1 item" : "\(p.totalItems) items")\(dest)"
        var d = p.currentName
        if p.totalBytes > 0 { d += " — \(FileFormat.size(p.doneBytes)) of \(FileFormat.size(p.totalBytes))" }
        detail.stringValue = d
        bar.doubleValue = p.fraction
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = CGRect(x: 12, y: 40, width: w - 52, height: 18)
        detail.frame = CGRect(x: 12, y: 22, width: w - 52, height: 16)
        bar.frame = CGRect(x: 12, y: 6, width: w - 52, height: 12)
        cancel.frame = CGRect(x: w - 36, y: 18, width: 28, height: 28)
    }
}

final class JobsPanel {
    /// Like KDE, progress only shows for jobs that take a moment.
    private static let showDelay: TimeInterval = 0.6
    private static let width: CGFloat = 380
    private static let rowHeight: CGFloat = 64
    private static let titleHeight: CGFloat = 28
    /// Distance from the screen's right and bottom edges.
    private static let margin: CGFloat = 20

    private var panel: NSPanel?
    private var rows: [JobRowView] = []
    private var showTimer: Timer?

    func add(_ job: FileJob) {
        rows.append(JobRowView(job: job))
        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in self?.relayout() }
    }

    func update(_ job: FileJob, _ p: JobProgress) { row(of: job)?.update(p) }

    func finish(_ job: FileJob) {
        guard let row = row(of: job) else { return }
        rows.removeAll { $0 === row }
        row.removeFromSuperview()
        if rows.isEmpty { panel?.orderOut(nil) } else { relayout() }
    }

    private func row(of job: FileJob) -> JobRowView? { rows.first { $0.job === job } }

    private func relayout() {
        guard !rows.isEmpty else { return }
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight + Self.titleHeight), styleMask: [.titled, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.title = "File Operations"
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.titlebarAppearsTransparent = true
            p.appearance = NSAppearance(named: .darkAqua)
            p.backgroundColor = Theme.windowBackground
            panel = p
        }
        guard let p = panel, let content = p.contentView else { return }
        let h = CGFloat(rows.count) * Self.rowHeight + Self.titleHeight
        content.subviews.forEach { $0.removeFromSuperview() }
        for (i, r) in rows.enumerated() {
            r.frame = CGRect(x: 0, y: h - Self.titleHeight - CGFloat(i + 1) * Self.rowHeight, width: Self.width, height: Self.rowHeight)
            content.addSubview(r)
        }
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrame(CGRect(x: vf.maxX - Self.width - Self.margin, y: vf.minY + Self.margin, width: Self.width, height: h), display: true)
        }
        p.orderFront(nil)
    }
}
