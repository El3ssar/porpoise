import Foundation

/// Maps folder artwork onto a chosen colour while retaining its highlights, shadows and neutral emblems.
/// The usable lightness interval also gives black, white and very pale colour-well choices visible relief.
public enum FolderColor {
    public static func tint(_ color: ThemeColor, variant: String) -> ThemeColor {
        let presets: [String: ThemeColor] = [
            "blue": ThemeColor(65, 145, 225), "green": ThemeColor(68, 166, 102), "red": ThemeColor(215, 80, 83),
            "orange": ThemeColor(224, 143, 57), "yellow": ThemeColor(218, 183, 58), "purple": ThemeColor(151, 105, 210),
            "pink": ThemeColor(219, 115, 169), "grey": ThemeColor(140, 148, 158),
        ]
        return presets[variant] ?? color
    }

    public static func map(_ source: ThemeColor, to target: ThemeColor, monochrome: Bool = false) -> ThemeColor {
        let values = [source.red, source.green, source.blue].map { Double($0) / 255 }
        let high = values.max()!, low = values.min()!
        // Neutral emblems, white paper and black shadows retain their contrast on coloured artwork.
        if !monochrome && high - low < 0.08 && high > 0.15 { return source }
        let rgb = [target.red, target.green, target.blue].map { Double($0) / 255 }
        let maxTarget = rgb.max()!, minTarget = rgb.min()!
        let lightness = (maxTarget + minTarget) / 2
        let base = min(0.72, max(0.32, lightness))
        let delta = ((high + low) / 2 - 0.55) * (monochrome ? 0.3 : 0.65)
        let mapped = min(0.88, max(0.18, base + delta))
        // Shift all channels together: preserve hue and cap saturation only when the gamut requires it.
        let scale = lightness > 0 && lightness < 1 ? min(mapped / lightness, (1 - mapped) / (1 - lightness)) : 0
        let out = rgb.map { min(255, max(0, Int(((($0 - lightness) * scale + mapped) * 255).rounded()))) }
        return ThemeColor(out[0], out[1], out[2])
    }
}
