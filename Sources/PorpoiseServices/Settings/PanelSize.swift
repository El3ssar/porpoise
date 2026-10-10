import Foundation

/// Remembered sizes of the window's panels (Settings keys), their defaults and limits.
public enum PanelSize: String {
    case sidebarWidth = "width.left", informationWidth = "width.right", terminalHeight = "height.terminal"

    public var defaultValue: CGFloat {
        switch self {
        case .sidebarWidth: 160
        case .informationWidth: 280
        case .terminalHeight: 220
        }
    }
    /// Largest share of the window a panel may take; the files always keep the rest.
    public var maxShare: CGFloat { self == .terminalHeight ? 0.7 : 0.45 }
    /// Room the files keep next to (below) the panel before it gives way in a small window.
    public var filesMinimum: CGFloat { self == .terminalHeight ? 150 : 280 }
    public var minimum: CGFloat {
        switch self {
        case .sidebarWidth: 120
        case .informationWidth: 200
        case .terminalHeight: 80
        }
    }

    /// The remembered size, kept within limits for a window/split of `extent` points (a bad saved value, e.g. from a
    /// transient layout, must never let a panel swallow the files).
    public func saved(in extent: CGFloat) -> CGFloat {
        let v = Settings.store.double(forKey: rawValue).nonZero.map { CGFloat($0) } ?? defaultValue
        return clamp(v, extent: extent) ?? min(defaultValue, max(minimum, extent * maxShare))
    }

    public func save(_ v: CGFloat, in extent: CGFloat) {
        if let ok = clamp(v, extent: extent), ok == v { Settings.store.set(Double(v), forKey: rawValue) }
    }

    private func clamp(_ v: CGFloat, extent: CGFloat) -> CGFloat? {
        guard extent > 0, v >= minimum, v <= extent * maxShare else { return nil }
        return v
    }

    /// The size the panel gets in a split of `extent` points: its remembered size, as far as the files keep
    /// `filesMinimum`; in a window too small for both it gives way, down to its minimum (or its share).
    public func fitted(in extent: CGFloat, divider: CGFloat) -> CGFloat {
        let room = extent - filesMinimum - divider
        return max(min(saved(in: extent), room), floor(in: extent))
    }

    /// The smallest the panel gets: its minimum, or less in a window too small to give it that share.
    private func floor(in extent: CGFloat) -> CGFloat { max(0, min(minimum, extent * maxShare)) }

    /// Divider positions a drag may reach, so the dragged size stays one that `save` keeps: the panel between its
    /// minimum and its share, the files at least `filesMinimum`. For a panel after the files (Information,
    /// Terminal) the position is the files' extent; for the sidebar it is the panel's own width.
    public func dividerRange(in extent: CGFloat, divider: CGFloat) -> ClosedRange<CGFloat> {
        let smallest = floor(in: extent)
        let largest = max(smallest, min(extent * maxShare, extent - filesMinimum - divider))
        if self == .sidebarWidth { return smallest...largest }
        return (extent - divider - largest)...(extent - divider - smallest)
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
