import AppKit
import PorpoiseCore
import PorpoiseServices

/// The windows of "Folders, tabs, and window state from last time", each as a `WindowLayout` (what named workspaces
/// keep too): its frame, tabs, panes with their view settings, filters and scroll positions, splits and panels. Saved
/// shortly after any change, so a crash or a forced quit loses at most a moment, and at quit.
///
/// Stored under "session" as one JSON layout per window, so a window that can't be read (a newer format) doesn't take
/// the others with it. What earlier versions saved there, [[["url": …, "split": …]]] with the window's frame and
/// active tab in its first tab, reads as before.
struct SessionState: Equatable {
    var windows: [WindowLayout]

    static let key = "session"

    init(windows: [WindowLayout]) { self.windows = windows }

    /// The stored form; nil, or anything else, gives no windows.
    init(stored: Any?) {
        if let list = stored as? [Data] {
            windows = list.compactMap { try? JSONDecoder().decode(WindowLayout.self, from: $0).normalized }
        } else {
            windows = (stored as? [[[String: String]]] ?? []).compactMap(Self.earlier)
        }
    }

    var stored: [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return windows.compactMap { try? encoder.encode($0) }
    }

    /// The session as JSON objects (the debug bridge reports it so).
    var json: [Any] { stored.compactMap { try? JSONSerialization.jsonObject(with: $0) } }

    /// A window as earlier versions saved it: its tabs and splits, and (in its first tab) its frame and active tab.
    /// Its panels were the ones last shown in any window.
    private static func earlier(_ saved: [[String: String]]) -> WindowLayout? {
        let tabs = saved.enumerated().compactMap { i, d -> (index: Int, tab: TabLayout)? in
            guard let u = d["url"].flatMap(URL.init(string:)) else { return nil }
            return (i, TabLayout(primary: PaneLayout(url: u), secondary: d["split"].flatMap(URL.init(string:)).map { PaneLayout(url: $0) }))
        }
        guard !tabs.isEmpty, let info = saved.first else { return nil }
        let active = info["active"].flatMap(Int.init) ?? 0
        let frame = info["frame"].map(NSRectFromString).map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
        let store = Settings.store
        let panels = PanelLayout(
            places: store.object(forKey: "panel.places") as? Bool ?? true, folders: store.bool(forKey: "panel.folders"),
            information: store.bool(forKey: "panel.info"), terminal: store.bool(forKey: "panel.terminal"), shelf: store.bool(forKey: "panel.shelf"))
        // A tab that can't be read is left out: the active one is then the nearest kept tab before it.
        return WindowLayout(tabs: tabs.map(\.tab), activeTab: tabs.lastIndex { $0.index <= active } ?? 0, panels: panels, frame: frame)
    }

    // MARK: - Restoring

    /// What can be reopened, and the names of the folders that can't: a local folder that is gone (deleted, or on a
    /// disk that was ejected) closes its tab, or just its side of a split, and a window left without tabs is not
    /// reopened. Each active tab stays the one that was active, or the nearest one before it. Remote locations are
    /// kept: an offline server says so in its tab when it is opened, and can be tried again. A frame no longer on any
    /// screen (a display that was disconnected) is dropped, so the window opens where a new one would.
    func available(exists: (URL) -> Bool = SessionState.exists, screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> (
        session: SessionState, missing: [String]
    ) {
        var missing: [String] = []
        func shown(_ p: PaneLayout) -> Bool {
            guard exists(p.url), p.columnRoot.map(exists) ?? true else {
                missing.append(p.url.lastPathComponent)
                return false
            }
            return true
        }
        let kept = windows.compactMap { w -> WindowLayout? in
            var w = w
            let indexed = w.tabs.enumerated().compactMap { i, t -> (index: Int, tab: TabLayout)? in
                guard shown(t.primary) else { return nil }
                var t = t
                if let s = t.secondary, !shown(s) {
                    t.secondary = nil
                    t.activeIsSecondary = false
                    t.linked = false
                }
                return (i, t)
            }
            guard !indexed.isEmpty else { return nil }
            w.tabs = indexed.map(\.tab)
            w.activeTab = indexed.lastIndex { $0.index <= w.activeTab } ?? 0
            if let f = w.frame, f.count == 4, !screens.contains(where: { $0.intersects(NSRect(x: f[0], y: f[1], width: f[2], height: f[3])) }) {
                w.frame = nil
            }
            return w
        }
        return (SessionState(windows: kept), missing)
    }

    /// Whether `url` can be shown: local folders must still be there; anything else is tried when shown.
    static func exists(_ url: URL) -> Bool { !url.isFileURL || FileManager.default.fileExists(atPath: url.path) }

    /// The message shown when some folders couldn't be reopened.
    static func missingMessage(_ names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return "“\(names[0])” is no longer available, so it wasn't reopened."
        default: return "\(names.count) folders are no longer available, so they weren't reopened."
        }
    }
}
