import AppKit
import PorpoiseCore
import PorpoiseServices

/// Maintains Dock progress and quietly presents the compact transfer window while Porpoise is active.
final class JobsPanel {
    private var timer: Timer?
    func add() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func finish() { refresh() }
    private func refresh() {
        let jobs = FileOperationsController.shared.activities.filter { $0.state.isActive }
        guard !jobs.isEmpty else {
            timer?.invalidate(); timer = nil; NSApp.dockTile.contentView = nil; NSApp.dockTile.display(); return
        }
        // Never bring Porpoise over another app or take focus from a conflict sheet. Very short jobs need no window.
        if NSApp.isActive, !Settings.isTesting,
            jobs.contains(where: { Date().timeIntervalSince($0.startedAt ?? Date()) >= 0.6 })
        {
            ActivityWindowController.shared.showProgress()
        }
        guard jobs.contains(where: { Date().timeIntervalSince($0.startedAt ?? Date()) > 2 }) else { return }
        let view = NSApp.dockTile.contentView as? TransferDockView ?? TransferDockView(frame: CGRect(origin: .zero, size: NSApp.dockTile.size))
        view.fraction = ActivityPresentation.aggregateFraction(jobs)
        NSApp.dockTile.contentView = view; NSApp.dockTile.display()
    }
}
private final class TransferDockView: NSView {
    var fraction = 0.0
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let track = CGRect(x: bounds.width * 0.13, y: bounds.height * 0.08, width: bounds.width * 0.74, height: 8)
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: track, xRadius: Tokens.Radius.small, yRadius: Tokens.Radius.small).fill()
        Theme.accent.setFill();
        NSBezierPath(
            roundedRect: CGRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, fraction)), height: track.height),
            xRadius: Tokens.Radius.small,
            yRadius: Tokens.Radius.small
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
