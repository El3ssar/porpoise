import Foundation

public enum ViewMode: String, Codable, CaseIterable, Sendable {
    case icons, compact, details

    public var title: String {
        switch self {
        case .icons: return "Icons"
        case .compact: return "Compact"
        case .details: return "Details"
        }
    }

    public var iconName: String {
        switch self {
        case .icons: return "view-list-icons"
        case .compact: return "view-list-details"
        case .details: return "view-list-tree"
        }
    }

    /// Default zoom level (0–16) for the icon size, matching Dolphin.
    public var defaultZoom: Int {
        switch self {
        case .icons: return 2       // 32 px
        case .compact, .details: return 0 // 16 px
        }
    }

    /// Default zoom level used when previews are on.
    public var defaultPreviewZoom: Int {
        switch self {
        case .icons: return 4       // 64 px
        case .compact, .details: return 2 // 32 px
        }
    }
}

/// Roles = columns / sort keys / group keys / additional information (Dolphin's "roles").
public enum ItemRole: String, Codable, CaseIterable, Sendable {
    case name, size, modificationTime, creationTime, accessTime, type, path, extension_, permissions, owner, group,
         linkDestination, tags

    public var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modificationTime: return "Modified"
        case .creationTime: return "Created"
        case .accessTime: return "Accessed"
        case .type: return "Type"
        case .path: return "Path"
        case .extension_: return "File Extension"
        case .permissions: return "Permissions"
        case .owner: return "Owner"
        case .group: return "User Group"
        case .linkDestination: return "Link Destination"
        case .tags: return "Tags"
        }
    }

    /// Roles shown in menus (Sort By, Group By, Show Additional Information, column picker).
    public static var menuRoles: [ItemRole] {
        [.name, .size, .modificationTime, .creationTime, .accessTime, .type, .tags]
    }

    public static var otherRoles: [ItemRole] {
        [.path, .extension_, .linkDestination, .permissions, .owner, .group]
    }

    /// Ascending / descending labels in the Sort By menu, as Dolphin words them.
    public var orderLabels: (ascending: String, descending: String) {
        switch self {
        case .name: return ("A-Z", "Z-A")
        case .size: return ("Smallest First", "Largest First")
        case .modificationTime, .creationTime, .accessTime: return ("Oldest First", "Newest First")
        default: return ("Ascending", "Descending")
        }
    }

    /// Default Details column width in points.
    public var defaultColumnWidth: CGFloat {
        switch self {
        case .name: return 320
        case .size: return 90
        case .modificationTime, .creationTime, .accessTime: return 170
        case .type: return 160
        case .path, .linkDestination: return 240
        case .permissions: return 110
        default: return 100
        }
    }

    public var rightAligned: Bool { self == .size }
}

public enum SortOrder: String, Codable, Sendable { case ascending, descending }

/// Per-folder (or global) display settings, like Dolphin's ViewProperties / .directory files.
public struct ViewProperties: Codable, Equatable, Sendable {
    public var mode: ViewMode = .icons
    public var sortRole: ItemRole = .name
    public var sortOrder: SortOrder = .ascending
    public var foldersFirst: Bool = true
    public var hiddenLast: Bool = false
    public var groupRole: ItemRole? = nil
    public var groupSameAsSort: Bool = false
    public var showHidden: Bool = false
    public var previews: Bool = true
    /// Additional information per view mode: text under names (Icons/Compact) or columns after Name (Details).
    /// Dolphin's defaults: nothing extra for Icons/Compact, Size + Modified for Details.
    public var extraRoles: [String: [ItemRole]] = [:]
    /// Legacy integer zoom levels (older settings); `sizes` holds the continuous icon sizes.
    public var zoom: [String: Int] = [:]
    public var sizes: [String: Double] = [:]

    public init() {}

    private func key(_ mode: ViewMode) -> String { mode.rawValue + (previews ? ".preview" : "") }

    /// Icon size in points (continuous, 16–256).
    public func iconSize(for mode: ViewMode) -> CGFloat {
        if let s = sizes[key(mode)] { return CGFloat(s) }
        let level = zoom[key(mode)] ?? (previews ? mode.defaultPreviewZoom : mode.defaultZoom)
        return ZoomLevels.iconSize(for: level)
    }

    public mutating func setIconSize(_ size: CGFloat, for mode: ViewMode) {
        sizes[key(mode)] = Double(Swift.min(ZoomLevels.maxSize, Swift.max(ZoomLevels.minSize, size)))
        zoom.removeValue(forKey: key(mode))
    }

    public mutating func resetIconSize(for mode: ViewMode) {
        sizes.removeValue(forKey: key(mode))
        zoom.removeValue(forKey: key(mode))
    }

    /// Nearest Dolphin zoom level for the current size.
    public func zoomLevel(for mode: ViewMode) -> Int { ZoomLevels.nearestLevel(for: iconSize(for: mode)) }

    public mutating func setZoomLevel(_ level: Int, for mode: ViewMode) {
        setIconSize(ZoomLevels.iconSize(for: level), for: mode)
    }

    enum CodingKeys: String, CodingKey {
        case mode, sortRole, sortOrder, foldersFirst, hiddenLast, groupRole, groupSameAsSort, showHidden, previews, extraRoles, zoom, sizes
    }

    /// Tolerant decoding: settings saved by older versions (missing keys) keep their values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ViewMode.self, forKey: .mode) ?? .icons
        sortRole = try c.decodeIfPresent(ItemRole.self, forKey: .sortRole) ?? .name
        sortOrder = try c.decodeIfPresent(SortOrder.self, forKey: .sortOrder) ?? .ascending
        foldersFirst = try c.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? true
        hiddenLast = try c.decodeIfPresent(Bool.self, forKey: .hiddenLast) ?? false
        groupRole = try c.decodeIfPresent(ItemRole.self, forKey: .groupRole)
        groupSameAsSort = try c.decodeIfPresent(Bool.self, forKey: .groupSameAsSort) ?? false
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
        previews = try c.decodeIfPresent(Bool.self, forKey: .previews) ?? true
        extraRoles = try c.decodeIfPresent([String: [ItemRole]].self, forKey: .extraRoles) ?? [:]
        zoom = try c.decodeIfPresent([String: Int].self, forKey: .zoom) ?? [:]
        sizes = try c.decodeIfPresent([String: Double].self, forKey: .sizes) ?? [:]
    }

    public func roles(for mode: ViewMode) -> [ItemRole] {
        extraRoles[mode.rawValue] ?? (mode == .details ? [.size, .modificationTime] : [])
    }

    public mutating func setRoles(_ roles: [ItemRole], for mode: ViewMode) {
        extraRoles[mode.rawValue] = roles.filter { $0 != .name }
    }

    public var effectiveGroupRole: ItemRole? { groupSameAsSort ? sortRole : groupRole }

    /// Dolphin's defaults for special locations.
    public static func defaults(for url: URL) -> ViewProperties {
        var p = ViewProperties()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home + "/.Trash" {
            p.mode = .details
            p.setRoles([.path, .modificationTime], for: .details)
        } else if path == home + "/Downloads" {
            p.sortRole = .modificationTime
            p.sortOrder = .descending
            p.foldersFirst = false
        }
        return p
    }
}

/// A display change the app makes on its own for a while (Icons for a folder of photos, Details with a Path column for
/// search results). It is shown, never saved: `stored(_:)` gives what to save, putting the user's own value back into
/// every field that still shows the temporary one. A field the user changed since is theirs: it is saved as is, and the
/// override lets go of it.
public struct ViewOverride: Sendable {
    private var mode: (shown: ViewMode, original: ViewMode)?
    private var previews: (shown: Bool, original: Bool)?
    private var detailsRoles: (shown: [ItemRole]?, original: [ItemRole]?)?

    public init() {}

    public var isEmpty: Bool { mode == nil && previews == nil && detailsRoles == nil }

    /// Applies `change` to `props` as a temporary change. Applying again keeps the first original values.
    public mutating func apply(to props: inout ViewProperties, _ change: (inout ViewProperties) -> Void) {
        var p = props
        change(&p)
        if p.mode != props.mode { mode = (p.mode, mode?.original ?? props.mode) }
        if p.previews != props.previews { previews = (p.previews, previews?.original ?? props.previews) }
        let key = ViewMode.details.rawValue
        if p.extraRoles[key] != props.extraRoles[key] {
            detailsRoles = (p.extraRoles[key], detailsRoles.map { $0.original } ?? props.extraRoles[key])
        }
        props = p
    }

    /// What to save for the shown properties `props`.
    public mutating func stored(_ props: ViewProperties) -> ViewProperties {
        var p = props
        if let m = mode { if p.mode == m.shown { p.mode = m.original } else { mode = nil } }
        if let v = previews { if p.previews == v.shown { p.previews = v.original } else { previews = nil } }
        let key = ViewMode.details.rawValue
        if let r = detailsRoles {
            if p.extraRoles[key] == r.shown { p.extraRoles[key] = r.original } else { detailsRoles = nil }
        }
        return p
    }

    /// Ends the override: `props` with the user's own values back (fields the user changed since stay).
    public mutating func removed(from props: ViewProperties) -> ViewProperties {
        let p = stored(props)
        self = ViewOverride()
        return p
    }
}

public enum ZoomLevels {
    public static let min = 0
    public static let max = 16

    /// Dolphin's zoom levels: 16, 22, 32, 48, 64, then +16 per level up to 256.
    public static func iconSize(for level: Int) -> CGFloat {
        let l = clamp(level)
        let table: [CGFloat] = [16, 22, 32, 48, 64]
        if l < table.count { return table[l] }
        return 64 + CGFloat(l - 4) * 16
    }

    public static func clamp(_ l: Int) -> Int { Swift.max(min, Swift.min(max, l)) }

    public static let minSize: CGFloat = 16
    public static let maxSize: CGFloat = 256

    public static func nearestLevel(for size: CGFloat) -> Int {
        (min...max).min { abs(iconSize(for: $0) - size) < abs(iconSize(for: $1) - size) } ?? 0
    }

    /// Continuous level (0…16) for a size, interpolating between Dolphin's steps (slider position).
    public static func continuousLevel(for size: CGFloat) -> Double {
        for l in min..<max {
            let a = iconSize(for: l), b = iconSize(for: l + 1)
            if size <= b { return Double(l) + Double(Swift.max(0, size - a) / (b - a)) }
        }
        return Double(max)
    }

    /// Size for a continuous level (inverse of continuousLevel).
    public static func size(forContinuousLevel v: Double) -> CGFloat {
        let c = Swift.min(Double(max), Swift.max(Double(min), v))
        let l = Int(c.rounded(.down))
        if l >= max { return iconSize(for: max) }
        let a = iconSize(for: l), b = iconSize(for: l + 1)
        return a + (b - a) * CGFloat(c - Double(l))
    }

    /// Next/previous Dolphin step from an arbitrary size (Cmd+/Cmd- snap to levels).
    public static func step(from size: CGFloat, by delta: Int) -> CGFloat {
        if delta > 0 { return iconSize(for: (min...max).first { iconSize(for: $0) > size + 0.5 } ?? max) }
        return iconSize(for: (min...max).last { iconSize(for: $0) < size - 0.5 } ?? min)
    }
}
