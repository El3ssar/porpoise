import AppKit

extension ItemListView: ThumbnailOwner {
    /// Empty folders and non-preview content do not submit new work, but must still stop obsolete work.
    func thumbnailVisibilityChanged() {
        Thumbnails.shared.scheduler.requestReconcile()
    }

    /// On screen, or within half a screen of it: about to be scrolled to.
    func showsThumbnail(of url: URL) -> Bool {
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
            !NSApp.isHidden, !isHiddenOrHasHiddenAncestor, model.props.previews, let i = model.index(of: url), i < frames.count
        else {
            return false
        }
        let vr = visibleRect
        return frames[i].intersects(vr.insetBy(dx: -vr.width / 2, dy: -vr.height / 2))
    }
}
