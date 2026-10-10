import AppKit
import PorpoiseCore
import PorpoiseServices

/// Dolphin's status bar. Full width (default here): a thin translucent strip with folder/selection info on the left,
/// the icon-size slider and a disk-space bar on the right. Small mode: Dolphin's floating box in the view's corner.
final class StatusBarView: NSView {
    var text = "" { didSet { if text != oldValue { update() } } }
    /// A message shown for a moment instead of `text` (see `showMessage`).
    var temporaryText: String? { didSet { if temporaryText != oldValue { update() } } }
    var progress: Double? { didSet { if (progress == nil) != (oldValue == nil) { updateSpinner() }; update() } }
    var freeSpaceText = "" { didSet { if freeSpaceText != oldValue { needsLayout = true; canvas.needsDisplay = true } } }
    var usedFraction: Double = 0 { didSet { if usedFraction != oldValue { canvas.needsDisplay = true } } }
    /// Continuous zoom level (0…16) shown by the slider.
    var zoomLevel: Double = 4 { didSet { if abs(slider.doubleValue - zoomLevel) > 0.001 { slider.doubleValue = zoomLevel } } }
    var onZoom: ((Double) -> Void)?
    var onZoomCommit: (() -> Void)?
    var onDiskClick: (() -> Void)?
    var mode: StatusBarMode = .fullWidth { didSet { update(); updateChrome() } }

    private let material = TintedMaterialView(material: .titlebar, alpha: 0.82, blending: .withinWindow)
    private let hairline = NSView()
    private let slider = NSSlider(value: 4, minValue: 0, maxValue: 16, target: nil, action: nil)
    private let small = ZoomGlyph(large: false)
    private let large = ZoomGlyph(large: true)
    private let spinner = NSProgressIndicator()
    /// Text and the disk bar are drawn here, above the material.
    private let canvas = StatusCanvas()
    private var tempTimer: Timer?
    /// Free-space text plus bar (clickable); `.zero` when hidden.
    private var diskRect: CGRect = .zero

    static let height: CGFloat = 28
    private static let diskBarWidth: CGFloat = 72
    private static let sliderWidth: CGFloat = 96
    private static let messageDuration: TimeInterval = 2.5
    private static let diskFont = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.appearance = NSAppearance(named: .darkAqua)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        small.onClick = { [weak self] in self?.stepZoom(-1) }
        large.onClick = { [weak self] in self?.stepZoom(1) }
        canvas.owner = self
        // Clicks on the bar reach it (disk bar → Storage settings) rather than dragging the window.
        material.movesWindow = false
        for v in [material, canvas, hairline, spinner, small, slider, large] as [NSView] { addSubview(v) }
        setAccessibilityRole(.staticText)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateChrome() {
        let full = mode == .fullWidth
        material.isHidden = !full
        hairline.isHidden = !full
        wantsSlider = full && Settings.shared.showZoomSlider
        needsLayout = true
    }

    /// The zoom slider is on (full-width mode and the setting); layout shows it when there is room.
    private var wantsSlider = false
    /// Room the folder/selection text keeps before the slider and then the disk bar give way in a narrow view.
    private static let minTextWidth: CGFloat = 110
    /// Small glyph, slider and large glyph.
    private static let sliderGroupWidth: CGFloat = 18 + sliderWidth + 4 + 16

    private func updateSpinner() {
        if progress != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func sliderMoved() {
        onZoom?(slider.doubleValue)
        slider.toolTip = "Icon size: \(Int(ZoomLevels.size(forContinuousLevel: slider.doubleValue))) pt"
        if let e = NSApp.currentEvent, e.type == .leftMouseUp { onZoomCommit?() }
    }

    private func stepZoom(_ d: Int) {
        let s = ZoomLevels.step(from: ZoomLevels.size(forContinuousLevel: slider.doubleValue), by: d)
        slider.doubleValue = ZoomLevels.continuousLevel(for: s)
        onZoom?(slider.doubleValue)
        onZoomCommit?()
    }

    func showMessage(_ s: String) {
        temporaryText = s
        tempTimer?.invalidate()
        tempTimer = Timer.scheduledTimer(withTimeInterval: Self.messageDuration, repeats: false) { [weak self] _ in self?.temporaryText = nil }
    }

    var displayText: String { temporaryText ?? text }

    private var textAttrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle
        return [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.windowText.withAlphaComponent(0.88), .paragraphStyle: p]
    }

    /// Width the floating small bar needs.
    var smallWidth: CGFloat {
        let w = (displayText as NSString).size(withAttributes: [.font: Theme.font]).width + 18
        return progress != nil ? max(w, 180) : w
    }

    private func update() {
        setAccessibilityValue(displayText)
        superview?.needsLayout = true
        needsDisplay = true
        canvas.needsDisplay = true
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        canvas.frame = bounds
        canvas.needsDisplay = true
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        let cy = bounds.height / 2
        spinner.frame = CGRect(x: 10, y: cy - 8, width: 16, height: 16)
        // Right side: [disk text + bar] [gap] [small glyph · slider · large glyph]. In a narrow view the disk bar,
        // then the slider, give way so the text stays readable and nothing is pushed out of the bar.
        var right = bounds.width - 12
        let oldDiskRect = diskRect
        defer { if diskRect != oldDiskRect { window?.invalidateCursorRects(for: self) } }
        let textMin = 12 + Self.minTextWidth + 16
        let sliderW = wantsSlider ? Self.sliderGroupWidth : 0
        let diskW =
            freeSpaceText.isEmpty
            ? 0
            : (freeSpaceText as NSString).size(withAttributes: [.font: Self.diskFont]).width + 8 + Self.diskBarWidth + 18
        let showsDisk = diskW > 0 && textMin + sliderW + diskW <= right
        let showsSlider = wantsSlider && textMin + sliderW <= right
        slider.isHidden = !showsSlider
        small.isHidden = !showsSlider
        large.isHidden = !showsSlider
        if showsDisk {
            let w = diskW - 18
            diskRect = CGRect(x: right - w, y: 0, width: w, height: bounds.height)
            right = diskRect.minX - 18
        } else {
            diskRect = .zero
        }
        if showsSlider {
            large.frame = CGRect(x: right - 16, y: cy - 8, width: 16, height: 16)
            slider.frame = CGRect(x: large.frame.minX - 4 - Self.sliderWidth, y: cy - 8, width: Self.sliderWidth, height: 16)
            small.frame = CGRect(x: slider.frame.minX - 18, y: cy - 8, width: 16, height: 16)
        }
    }

    private var leftContentEnd: CGFloat {
        if !slider.isHidden { return small.frame.minX - 16 }
        if diskRect != .zero { return diskRect.minX - 16 }
        return bounds.width - 12
    }

    override func draw(_ dirty: NSRect) {}

    fileprivate func drawContent() {
        let r = bounds
        if mode == .small {
            if displayText.isEmpty && progress == nil { return }
            // Dolphin's small status bar: a box flush with the view's bottom-left corner.
            let box = CGRect(x: -6, y: 0.5, width: r.width + 5.5, height: r.height + 6)
            let p = NSBezierPath(roundedRect: box, xRadius: Theme.frameRadius, yRadius: Theme.frameRadius)
            Theme.windowBackground.setFill(); p.fill()
            Theme.frame.setStroke(); p.lineWidth = 1; p.stroke()
            let s = (displayText as NSString).size(withAttributes: [.font: Theme.font])
            (displayText as NSString).draw(
                in: CGRect(x: 8, y: (r.height - s.height) / 2, width: r.width - 16, height: s.height + 2),
                withAttributes: [.font: Theme.font, .foregroundColor: Theme.windowText])
            return
        }
        let attrs = textAttrs
        let s = (displayText as NSString).size(withAttributes: attrs)
        let tx: CGFloat = progress != nil ? 32 : 12
        (displayText as NSString).draw(
            in: CGRect(x: tx, y: (r.height - s.height) / 2, width: max(0, leftContentEnd - tx), height: s.height + 2),
            withAttributes: attrs)
        if diskRect != .zero { drawDisk() }
    }

    /// "786 GiB free" + a slim capsule showing used space (blue → amber → red as the disk fills).
    private func drawDisk() {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.diskFont, .foregroundColor: Theme.windowTextInactive.withAlphaComponent(0.85)]
        let ts = (freeSpaceText as NSString).size(withAttributes: attrs)
        let cy = bounds.height / 2
        (freeSpaceText as NSString).draw(at: CGPoint(x: diskRect.minX, y: cy - ts.height / 2), withAttributes: attrs)
        let bar = CGRect(x: diskRect.maxX - Self.diskBarWidth, y: cy - 3, width: Self.diskBarWidth, height: 6)
        let track = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
        Theme.windowText.withAlphaComponent(0.13).setFill()
        track.fill()
        let used = max(0.04, min(1, usedFraction))
        let fillRect = CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(used), height: bar.height)
        let colors: [NSColor] =
            used > 0.9
            ? [Theme.neutralText.mixed(with: .systemOrange, 0.6), Theme.negativeText]
            : (used > 0.75 ? [Theme.selectionAlternate, .systemOrange] : [Theme.selection.lighter(150), Theme.selectionAlternate])
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).addClip()
        NSGradient(colors: colors)?.draw(in: fillRect, angle: 0)
        // Soft top highlight for a little depth.
        NSColor.white.withAlphaComponent(0.18).setFill()
        CGRect(x: fillRect.minX, y: fillRect.minY, width: fillRect.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if diskRect.contains(p) { onDiskClick?() }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        if diskRect != .zero { addCursorRect(diskRect, cursor: .pointingHand) }
    }
}

/// Drawing surface of the status bar (sits above its material).
final class StatusCanvas: NSView {
    weak var owner: StatusBarView?
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) { owner?.drawContent() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
