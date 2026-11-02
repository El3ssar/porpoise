import AppKit
import PorpoiseCore

/// A bounded, static rendering of the transfer's measured samples. No sampling timer or per-file list lives here.
final class SpeedHistoryView: NSView {
    var samples: [TransferSpeedSample] = [] { didSet { needsDisplay = true; describe() } }
    private let empty = NSTextField(labelWithString: "Collecting transfer speed…")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        empty.font = Tokens.font(.footnote)
        empty.textColor = Theme.windowTextInactive
        empty.alignment = .center
        addSubview(empty)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Transfer speed over time")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        empty.frame = CGRect(x: 8, y: bounds.midY - 8, width: max(0, bounds.width - 16), height: 18)
        empty.isHidden = samples.count >= 2
    }

    private var valid: [TransferSpeedSample] { samples.filter { $0.elapsed.isFinite && $0.bytesPerSecond.isFinite && $0.bytesPerSecond >= 0 } }

    private func describe() {
        let values = valid
        let peak = values.map(\.bytesPerSecond).max() ?? 0
        setAccessibilityValueDescription(
            values.isEmpty ? "Waiting for measured speed samples" : "\(values.count) samples. Peak \(FileFormat.speed(peak)).")
        needsLayout = true
    }

    static func elapsedLabel(_ duration: TimeInterval) -> String {
        let value = duration.isFinite ? max(0, duration < 60 ? duration : duration / 60) : 0
        let count = Int(min(Double(Int.max / 2), value))
        let unit = duration < 60 ? (count == 1 ? "second" : "seconds") : (count == 1 ? "minute" : "minutes")
        return "Elapsed \(count) \(unit)"
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: 8, dy: 20)
        guard plot.width > 0, plot.height > 0 else { return }
        Theme.separator.withAlphaComponent(0.5).setStroke()
        let grid = NSBezierPath()
        for part in [0.0, 0.5, 1.0] {
            let y = plot.minY + plot.height * part
            grid.move(to: CGPoint(x: plot.minX, y: y)); grid.line(to: CGPoint(x: plot.maxX, y: y))
        }
        grid.lineWidth = 0.5; grid.stroke()
        let values = valid
        guard values.count >= 2, let last = values.last else { return }
        let duration = max(1, last.elapsed)
        let peak = max(1, values.map(\.bytesPerSecond).max() ?? 1)
        let segments = Dictionary(grouping: values, by: \.segment).values.sorted { ($0.first?.elapsed ?? 0) < ($1.first?.elapsed ?? 0) }
        for segment in segments {
            let points = segment.map { value in
                CGPoint(
                    x: plot.minX + min(1, max(0, value.elapsed / duration)) * plot.width,
                    y: plot.maxY - min(1, max(0, value.bytesPerSecond / peak)) * plot.height)
            }
            guard let start = points.first, let end = points.last else { continue }
            let line = NSBezierPath(); line.move(to: start)
            let area = NSBezierPath(); area.move(to: CGPoint(x: start.x, y: plot.maxY)); area.line(to: start)
            for point in points.dropFirst() { line.line(to: point); area.line(to: point) }
            area.line(to: CGPoint(x: end.x, y: plot.maxY)); area.close()
            Theme.activeText.withAlphaComponent(0.10).setFill(); area.fill()
            Theme.activeText.setStroke(); line.lineWidth = 1.5; line.lineJoinStyle = .round; line.stroke()
        }
        let style: [NSAttributedString.Key: Any] = [.font: Tokens.font(.footnote), .foregroundColor: Theme.windowTextInactive]
        (FileFormat.speed(peak) as NSString).draw(at: CGPoint(x: plot.minX, y: 0), withAttributes: style)
        (Self.elapsedLabel(duration) as NSString).draw(at: CGPoint(x: plot.minX, y: bounds.height - 16), withAttributes: style)
    }
}
