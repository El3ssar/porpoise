import AppKit

/// Back and Forward in Column view: each history entry keeps its columns as they were (the first one, each column's
/// size, the selection, where each column was scrolled), and going back to it puts them back.
extension ColumnBrowserView {
    struct Snapshot {
        var root: URL
        /// The focused column's folder: the history entry's own.
        var focused: URL
        var sizes: [ColumnSize]
        var previewWidth: CGFloat?
        /// The selection, when it's small (a large one isn't kept for every entry: the current item is).
        var selection: Set<URL>
        var current: URL?
        var anchor: URL?
        /// Where each of the other columns was scrolled, by folder.
        var origins: [URL: CGPoint]
    }

    static let keptSelection = 1000

    /// The columns as they are now.
    func snapshot() -> Snapshot {
        let model = container.model
        var origins: [URL: CGPoint] = [:]
        for c in before + [after].compactMap({ $0 }) { origins[Self.key(c.url)] = c.list.visibleRect.origin }
        return Snapshot(
            root: root, focused: container.url, sizes: sizes, previewWidth: previewWidth,
            selection: model.selection.count <= Self.keptSelection ? model.selection : [],
            current: model.currentURL, anchor: model.anchorURL, origins: origins)
    }

    /// After the pane went back to `s`'s folder (its columns and sizes already in place): its selection and the other
    /// columns' scroll positions.
    func apply(_ s: Snapshot) {
        if container.model.rows.isEmpty {
            // Not listed yet (its column had gone): once it is.
            let next = container.onNextLoad
            container.onNextLoad = { [weak self] in
                next?()
                guard let self, Self.key(self.container.url) == Self.key(s.focused) else { return }
                self.select(s)
            }
        } else {
            select(s)
        }
        for c in before + [after].compactMap({ $0 }) {
            guard let o = s.origins[Self.key(c.url)] else { continue }
            if c.model.rows.isEmpty {
                c.pendingOrigin = o
            } else {
                if c.list.frames.count != c.model.rows.count { c.list.computeLayout() }
                c.list.scroll(o)
            }
        }
    }

    private func select(_ s: Snapshot) {
        let model = container.model
        let selection = s.selection.filter { model.index(of: $0) != nil }
        if !selection.isEmpty { model.selection = selection }
        model.currentURL = s.current.flatMap { model.index(of: $0) != nil ? $0 : nil } ?? model.currentURL
        model.anchorURL = s.anchor ?? model.anchorURL
    }
}
