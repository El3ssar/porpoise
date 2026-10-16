import AppKit

/// A two-point comparison progress track. Values are real read fractions; the moving band means indeterminate work.
final class FileDiffProgressView: NSView {
    var minValue = 0.0
    var maxValue = 100.0
    var doubleValue = 0.0 {
        didSet { needsDisplay = true; setAccessibilityValue(doubleValue) }
    }
    var isIndeterminate = true {
        didSet { needsDisplay = true; if isIndeterminate { setAccessibilityValue("Comparing") } }
    }
    private var timer: Timer?
    private var phase: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator); setAccessibilityLabel("File comparison progress")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func startAnimation(_ sender: Any?) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.isIndeterminate && !self.isHidden {
                self.phase = (self.phase + 0.02).truncatingRemainder(dividingBy: 1); self.needsDisplay = true
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stopAnimation(_ sender: Any?) { timer?.invalidate(); timer = nil; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
        let path = NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1)
        Theme.separator.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState(); path.addClip(); Theme.accent.setFill()
        if isIndeterminate {
            let width = min(90, track.width * 0.3)
            NSRect(x: (track.width + width) * phase - width, y: track.minY, width: width, height: 2).fill()
        } else {
            let fraction = max(0, min(1, (doubleValue - minValue) / max(1, maxValue - minValue)))
            NSRect(x: 0, y: track.minY, width: track.width * fraction, height: 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
