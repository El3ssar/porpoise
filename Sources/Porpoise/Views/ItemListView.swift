import AppKit
import PorpoiseCore

protocol ItemListViewDelegate: AnyObject {
    func itemList(_ view: ItemListView, open items: [FileItem], inNewTab: Bool)
    func itemList(_ view: ItemListView, menuFor item: FileItem?) -> NSMenu?
    func itemList(_ view: ItemListView, drop urls: [URL], onto folder: URL, operation: NSDragOperation, event: NSEvent?)
    func itemList(_ view: ItemListView, rename item: FileItem, to name: String)
    func itemListDidBecomeActive(_ view: ItemListView)
    func itemList(_ view: ItemListView, hovered item: FileItem?)
    func itemListBackgroundDoubleClicked(_ view: ItemListView)
    func itemList(_ view: ItemListView, middleClicked item: FileItem)
    func itemListQuickLook(_ view: ItemListView)
}

/// Dolphin's KItemListView: one custom-drawn view for Icons, Compact and Details modes.
///
/// Split by concern: `+Layout` (geometry, hit testing), `+Drawing`, `+Mouse` (hover, clicks, rubber band, gestures),
/// `+Keyboard` (navigation, type-ahead), `+Rename`, `+DragDrop`. State the extensions share lives here.
final class ItemListView: NSView {
    let model: DirectoryModel
    weak var delegate: ItemListViewDelegate?
    var isActiveView = true { didSet { if isActiveView != oldValue { needsDisplay = true } } }
    /// Items cut to the clipboard (drawn dimmed); a view opened after the cut starts with them too.
    var cutURLs: Set<URL> = FileOperationsController.shared.cutURLs
    /// Dolphin's selection mode: plain clicks toggle items instead of replacing the selection.
    var selectionModeActive = false
    var mode: ViewMode { model.props.mode }

    // MARK: Layout output (+Layout)

    /// Item cells, in row order; sorted by y (Icons, Details) or by x (Compact), which hit testing relies on.
    var frames: [CGRect] = []
    var groupHeaderFrames: [CGRect] = []
    /// Icons: items per row.
    var columns = 1
    /// Compact: items per column.
    var rowsPerColumn = 1
    /// Details column widths; user-set widths are remembered (Settings), Name fills the rest unless resized.
    var columnWidths: [ItemRole: CGFloat] = [:]
    var detailsRoles: [ItemRole] = [.name]
    /// Details tree lines: per row, for each level 0...depth, whether a vertical line continues below.
    var treeLines: [[Bool]] = []
    /// Click targets of the cloud badges drawn so far (row → rect).
    var cloudRects: [Int: CGRect] = [:]

    // MARK: Text measurement caches (+Layout)

    /// Widths of strings in `font`: Compact layout measures every name, so zooming a big folder must not re-measure.
    var textWidthCache: [String: CGFloat] = [:]
    /// Wrapped and elided Icons-mode labels, used by drawing and by hit testing on every mouse move.
    var iconsLabelCache: [IconsLabelKey: (label: NSAttributedString, size: CGSize)] = [:]

    struct IconsLabelKey: Hashable {
        let text: String
        let width: CGFloat
        let maxLines: Int
    }

    // MARK: Interaction state

    var hoverIndex: Int? { didSet { if hoverIndex != oldValue { hoverChanged(oldValue) } } }
    /// The item the delegate was last told is hovered (rows can change under a still pointer).
    var hoveredURL: URL?
    var hoverOnMarker = false
    /// Hover highlight opacity per item while it fades in or out.
    var hoverAlpha: [URL: CGFloat] = [:]
    var hoverTimer: Timer?
    var trackingArea: NSTrackingArea?
    var rubberBand: CGRect?
    var rubberStart: CGPoint?
    var rubberBaseSelection: Set<URL> = []
    var mouseDownIndex: Int?
    var mouseDownPoint: CGPoint = .zero
    var mouseDownSelectedBefore = false
    var cloudRefreshPending = false
    var typeAhead = ""
    var typeAheadTime = Date.distantPast
    var renameField: NSTextField?
    var renamingItem: FileItem?
    var dropTargetIndex: Int?
    var dropOnBackground = false
    var dragOpenTimer: Timer?
    /// URLs on the pasteboard of the drag in progress, read once per drag (`draggingUpdated` runs on every move).
    var draggedURLCache: (sequence: Int, urls: [URL])?

    // MARK: Metrics

    static let pad: CGFloat = 2
    static let sidePadding: CGFloat = 20
    static let headerHeight: CGFloat = 26
    /// Margin around the items in Icons and Compact modes.
    static let margin: CGFloat = 8
    /// Details: indentation per tree level.
    static let indentPerLevel: CGFloat = 20

    /// The label font, cached: `Settings.labelFont` builds a new NSFont on every call.
    private(set) var font: NSFont
    private(set) var lineHeight: CGFloat
    /// Icon size; `liveIconSize` overrides it during pinch / slider / animated zoom (committed when done).
    var iconSize: CGFloat { liveIconSize ?? model.props.iconSize(for: model.props.mode) }
    private(set) var liveIconSize: CGFloat?
    /// True while a zoom is being saved (the container then keeps the scroll position).
    private(set) var committingZoom = false
    private var zoomCommitTimer: Timer?
    private var zoomAnimation: Timer?
    var onZoomPreview: ((CGFloat) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init(model: DirectoryModel) {
        self.model = model
        font = Settings.shared.labelFont
        lineHeight = Self.lineHeight(of: font)
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .URL])
        observers.append(NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { [weak self] n in
            self?.thumbnailReady(n)
        })
        observers.append(NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        for t in [hoverTimer, zoomCommitTimer, zoomAnimation, dragOpenTimer] { t?.invalidate() }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shown in place of this list (the app library): focus given to the list goes there instead.
    weak var focusRedirect: NSView?

    override func becomeFirstResponder() -> Bool {
        // Decided on the next turn: the location may change in this one (leaving Applications clears the redirect).
        if focusRedirect != nil, let w = window {
            DispatchQueue.main.async { [weak self] in
                guard let r = self?.focusRedirect, !r.isHiddenOrHasHiddenAncestor else { return }
                w.makeFirstResponder(r)
            }
        }
        delegate?.itemListDidBecomeActive(self)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    private static func lineHeight(of font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) + 1 }

    private func settingsChanged() {
        let f = Settings.shared.labelFont
        if f != font {
            font = f
            lineHeight = Self.lineHeight(of: f)
            textWidthCache = [:]
        }
        // The number of label lines may have changed too; refilling this for the visible items is cheap.
        iconsLabelCache = [:]
        relayout()
    }

    private func thumbnailReady(_ n: Notification) {
        guard let url = n.object as? URL else { return }
        // The item itself, or its folder (whose preview shows it).
        for u in [url, url.deletingLastPathComponent()] {
            if let i = model.index(of: u), i < frames.count { setNeedsDisplay(frames[i].insetBy(dx: -4, dy: -4)) }
        }
    }

    // MARK: - Zoom

    /// Shows a new icon size immediately, keeping the item under `anchor` (or the current one) in place.
    func previewZoom(_ size: CGFloat, anchor: CGPoint? = nil, commitAfter delay: TimeInterval? = 0.35) {
        let s = min(ZoomLevels.maxSize, max(ZoomLevels.minSize, size))
        let vr = visibleRect
        // Anchor: the item under the pointer (or the current item), kept at the same spot on screen.
        var anchorIndex = anchor.flatMap { index(at: $0) }
        if anchorIndex == nil { anchorIndex = model.currentURL.flatMap { model.index(of: $0) } }
        if anchorIndex == nil { anchorIndex = candidateIndexes(in: vr).first }
        if let i = anchorIndex, i >= frames.count { anchorIndex = nil }
        let before = anchorIndex.map { frames[$0].origin } ?? .zero
        liveIconSize = s
        computeLayout()
        if let i = anchorIndex, i < frames.count {
            let after = frames[i].origin
            let target = CGPoint(x: mode == .compact ? max(0, vr.minX + after.x - before.x) : vr.minX, y: max(0, vr.minY + after.y - before.y))
            scroll(target)
        }
        needsDisplay = true
        onZoomPreview?(s)
        zoomCommitTimer?.invalidate()
        if let d = delay {
            zoomCommitTimer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in self?.commitZoom() }
        }
    }

    /// Animates to a size (Cmd+= / Cmd+-), then commits it.
    func animateZoom(to size: CGFloat) {
        zoomAnimation?.invalidate()
        let from = iconSize
        let start = Date()
        // Huge folders jump straight there: every frame is a full layout.
        let duration = model.rows.count > 4000 ? 0.0 : 0.16
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = duration == 0 ? 1 : min(1, Date().timeIntervalSince(start) / duration)
            let eased = 1 - pow(1 - p, 3)
            self.previewZoom(from + (size - from) * CGFloat(eased), commitAfter: nil)
            if p >= 1 { t.invalidate(); self.commitZoom() }
        }
        zoomAnimation = t
        RunLoop.main.add(t, forMode: .common)
    }

    func commitZoom() {
        zoomCommitTimer?.invalidate()
        guard let s = liveIconSize else { return }
        var p = model.props
        p.setIconSize(s.rounded(), for: p.mode)
        // Saving the size must not move the view: the pinch already placed it around the fingers.
        let origin = visibleRect.origin
        liveIconSize = nil
        committingZoom = true
        defer { committingZoom = false }
        if p != model.props {
            model.props = p
            model.saveProps()
        } else {
            relayout()
        }
        scroll(origin)
    }
}

// MARK: - Services / Quick Actions (Finder lists them in the context menu)

extension ItemListView: NSServicesMenuRequestor {
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let t = sendType, returnType == nil, [.fileURL, FileDragWriter.filenames].contains(t),
           !model.selection.isEmpty, model.selection.allSatisfy(\.isFileURL) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let urls = model.selectedItems.map(\.url)
        guard !urls.isEmpty else { return false }
        pboard.clearContents()
        return pboard.writeObjects(urls as [NSURL])
    }
}
