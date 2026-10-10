import AppKit
import PorpoiseCore

/// Zoom slider embedded in the View Settings menu (Dolphin shows one there).
final class ZoomSliderMenuView: NSView {
    let slider: NSSlider
    let onChange: (Int) -> Void

    init(level: Int, onChange: @escaping (Int) -> Void) {
        slider = NSSlider(value: Double(level), minValue: Double(ZoomLevels.min), maxValue: Double(ZoomLevels.max), target: nil, action: nil)
        self.onChange = onChange
        super.init(frame: CGRect(x: 0, y: 0, width: 240, height: 30))
        let minus = NSImageView(image: Icons.shared.image("zoom-out", size: 16) ?? NSImage())
        let plus = NSImageView(image: Icons.shared.image("zoom-in", size: 16) ?? NSImage())
        minus.frame = CGRect(x: 16, y: 7, width: 16, height: 16)
        plus.frame = CGRect(x: 208, y: 7, width: 16, height: 16)
        slider.frame = CGRect(x: 38, y: 5, width: 164, height: 20)
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        [minus, slider, plus].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange(slider.integerValue) }
}
