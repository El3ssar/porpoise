import Foundation

/// Compact mode's columns (Dolphin's compact view): items flow top to bottom, then into the next column, and every
/// column is as wide as the others, so one long name doesn't push the rest of the view away. Longer names are elided.
public enum CompactColumns {
    /// Width of the text in every column: the widest text in the folder, up to a limit. The limit is `maxChars`
    /// characters (Settings › Compact › Maximum width), or with no maximum set, one that grows with the zoom level.
    public static func textWidth(widest: CGFloat, iconSize: CGFloat, charWidth: CGFloat, maxChars: Int, minimum: CGFloat) -> CGFloat {
        let chars = maxChars > 0 ? CGFloat(maxChars) : defaultChars(iconSize: iconSize)
        return ceil(max(minimum, min(widest, chars * charWidth)))
    }

    /// Characters a column shows with no maximum set: 24 at the smallest zoom, 36 at 64 pt, 84 at the largest.
    public static func defaultChars(iconSize: CGFloat) -> CGFloat { 20 + iconSize / 4 }
}
