import AppKit

extension ItemListView: ThumbnailOwner {
    /// On screen, or within half a screen of it: about to be scrolled to.
    func showsThumbnail(of url: URL) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, model.props.previews, let i = model.index(of: url), i < frames.count else {
            return false
        }
        let vr = visibleRect
        return frames[i].intersects(vr.insetBy(dx: -vr.width / 2, dy: -vr.height / 2))
    }
}
