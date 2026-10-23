import Foundation

/// What a browser window shows, as data: its tabs (each with one or two panes), the panels and their sizes. Named
/// workspaces keep copies of it; applying one gives the window the same view again.
public struct WindowLayout: Codable, Equatable, Sendable {
    /// The format; a newer one than this version reads is refused, not half applied.
    public static let currentVersion = 1

    public var version = WindowLayout.currentVersion
    public var tabs: [TabLayout]
    /// Index into `tabs` of the tab shown.
    public var activeTab: Int
    public var panels: PanelLayout
    /// The window's frame (x, y, width, height); nil leaves the window where it is.
    public var frame: [Double]?

    public init(tabs: [TabLayout], activeTab: Int = 0, panels: PanelLayout = PanelLayout(), frame: [Double]? = nil) {
        self.tabs = tabs
        self.activeTab = activeTab
        self.panels = panels
        self.frame = frame
    }

    /// The layout as it can be applied: at least one tab, a tab index that exists, a frame with four finite numbers.
    public var normalized: WindowLayout? {
        guard version <= Self.currentVersion, !tabs.isEmpty else { return nil }
        var l = self
        l.activeTab = min(max(0, activeTab), tabs.count - 1)
        if let f = frame, f.count != 4 || !f.allSatisfy(\.isFinite) || f[2] <= 0 || f[3] <= 0 { l.frame = nil }
        l.tabs = tabs.map { t in
            var t = t
            if let f = t.splitFraction, !(f.isFinite && f > 0 && f < 1) { t.splitFraction = nil }
            if t.secondary == nil { t.activeIsSecondary = false }
            return t
        }
        return l
    }

    /// Every location the layout shows, primary panes first.
    public var locations: [URL] { tabs.flatMap { [$0.primary.url] + ($0.secondary.map { [$0.url] } ?? []) } }
}

/// One tab: a pane, or two side by side.
public struct TabLayout: Codable, Equatable, Sendable {
    public var primary: PaneLayout
    public var secondary: PaneLayout?
    public var activeIsSecondary = false
    /// Where the split handle sits, as a share of the tab's width (0…1); nil for the remembered position.
    public var splitFraction: Double?
    /// A name the user gave the tab (Rename Tab…).
    public var title: String?
    /// Linked browsing between the two panes.
    public var linked = false

    public init(
        primary: PaneLayout, secondary: PaneLayout? = nil, activeIsSecondary: Bool = false, splitFraction: Double? = nil,
        title: String? = nil, linked: Bool = false
    ) {
        self.primary = primary
        self.secondary = secondary
        self.activeIsSecondary = activeIsSecondary
        self.splitFraction = splitFraction
        self.title = title
        self.linked = linked
    }

    // Missing keys take their defaults, so a layout written by an older version still reads.
    enum CodingKeys: String, CodingKey { case primary, secondary, activeIsSecondary, splitFraction, title, linked }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primary = try c.decode(PaneLayout.self, forKey: .primary)
        secondary = try c.decodeIfPresent(PaneLayout.self, forKey: .secondary)
        activeIsSecondary = try c.decodeIfPresent(Bool.self, forKey: .activeIsSecondary) ?? false
        splitFraction = try c.decodeIfPresent(Double.self, forKey: .splitFraction)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked) ?? false
    }
}

/// One pane: its location and how it shows it.
public struct PaneLayout: Codable, Equatable, Sendable {
    /// The folder shown (in Column view, the focused column's).
    public var url: URL
    /// Column view: the folder the columns start from, when it isn't `url`.
    public var columnRoot: URL?
    /// The view settings shown; nil for the folder's own.
    public var props: ViewProperties?
    /// The filter bar's text, mode and case; nil when it's empty.
    public var filter: NameFilter?
    /// The filter bar shows (also with no text).
    public var filterBarShown = false
    /// The filter stays when changing folders.
    public var filterLocked = false
    /// The list's scroll position (top-left of what's in view).
    public var scroll: [Double]?

    public init(
        url: URL, columnRoot: URL? = nil, props: ViewProperties? = nil, filter: NameFilter? = nil, filterBarShown: Bool = false,
        filterLocked: Bool = false, scroll: [Double]? = nil
    ) {
        self.url = url
        self.columnRoot = columnRoot
        self.props = props
        self.filter = filter
        self.filterBarShown = filterBarShown
        self.filterLocked = filterLocked
        self.scroll = scroll
    }

    enum CodingKeys: String, CodingKey { case url, columnRoot, props, filter, filterBarShown, filterLocked, scroll }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        columnRoot = try c.decodeIfPresent(URL.self, forKey: .columnRoot)
        props = try? c.decodeIfPresent(ViewProperties.self, forKey: .props)
        filter = try? c.decodeIfPresent(NameFilter.self, forKey: .filter)
        filterBarShown = try c.decodeIfPresent(Bool.self, forKey: .filterBarShown) ?? false
        filterLocked = try c.decodeIfPresent(Bool.self, forKey: .filterLocked) ?? false
        scroll = try c.decodeIfPresent([Double].self, forKey: .scroll)
    }
}

/// Which panels show, and their sizes (nil keeps the current size).
public struct PanelLayout: Codable, Equatable, Sendable {
    public var places = true
    public var folders = false
    public var information = false
    public var terminal = false
    public var shelf = false
    public var sidebarWidth: Double?
    public var informationWidth: Double?
    public var terminalHeight: Double?

    public init(
        places: Bool = true, folders: Bool = false, information: Bool = false, terminal: Bool = false, shelf: Bool = false,
        sidebarWidth: Double? = nil, informationWidth: Double? = nil, terminalHeight: Double? = nil
    ) {
        self.places = places
        self.folders = folders
        self.information = information
        self.terminal = terminal
        self.shelf = shelf
        self.sidebarWidth = sidebarWidth
        self.informationWidth = informationWidth
        self.terminalHeight = terminalHeight
    }

    enum CodingKeys: String, CodingKey {
        case places, folders, information, terminal, shelf, sidebarWidth, informationWidth, terminalHeight
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = try c.decodeIfPresent(Bool.self, forKey: .places) ?? true
        folders = try c.decodeIfPresent(Bool.self, forKey: .folders) ?? false
        information = try c.decodeIfPresent(Bool.self, forKey: .information) ?? false
        terminal = try c.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        shelf = try c.decodeIfPresent(Bool.self, forKey: .shelf) ?? false
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth)
        informationWidth = try c.decodeIfPresent(Double.self, forKey: .informationWidth)
        terminalHeight = try c.decodeIfPresent(Double.self, forKey: .terminalHeight)
    }
}

/// A saved window layout with the name the user gave it.
public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layout: WindowLayout
    public var saved: Date

    public init(id: UUID = UUID(), name: String, layout: WindowLayout, saved: Date = Date()) {
        self.id = id
        self.name = name
        self.layout = layout
        self.saved = saved
    }

    /// A name as stored: trimmed, on one line, at most 80 characters; nil when nothing is left.
    public static func cleanName(_ raw: String) -> String? {
        let one = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !one.isEmpty else { return nil }
        return String(one.prefix(80))
    }

    /// Workspaces as they're listed: by name, ignoring case and diacritics, numbers in order ("Work 2" before "Work 10").
    public static func sorted(_ all: [Workspace]) -> [Workspace] {
        all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The workspace in `all` with this name (ignoring case), the one a save with that name replaces.
    public static func named(_ name: String, in all: [Workspace]) -> Workspace? {
        all.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}
