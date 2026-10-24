import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

/// "Configure Dolphin" as a native Mac settings window: Dolphin's options on eight pages (`SettingsPages`), General first.
final class SettingsWindowController: SecondaryWindowController {
    /// The Settings window, for the pages' sheets (whichever window happens to be key).
    private(set) static weak var window: NSWindow?

    /// Where the page shown last is kept, so Settings reopens on it.
    static let lastPageKey = "settingsLastPage"

    /// The pages' builders, kept so their observers live (and are removed) with the window.
    private var builders: [FormBuilder] = []
    init(page initialPage: String? = nil) {
        let tabs = ThemedTabViewController()
        tabs.tabStyle = .toolbar
        var builders: [FormBuilder] = []
        func page(_ title: String, _ symbol: String, _ build: (FormBuilder) -> Void) {
            let vc = NSViewController()
            let fb = FormBuilder()
            builders.append(fb)
            build(fb)
            // Long pages scroll, like KDE's settings pages.
            let scroll = FadingScrollView(frame: CGRect(x: 0, y: 0, width: 760, height: 580))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            let doc = FlippedView()
            doc.addSubview(fb.view)
            fb.view.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = doc
            doc.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                fb.view.topAnchor.constraint(equalTo: doc.topAnchor),
                fb.view.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                fb.view.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                fb.view.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            ])
            vc.view = scroll
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        for p in SettingsPages.all { page(p.title, p.symbol, p.build) }

        // The page asked for; else General the first time, then the page shown last (an old page's name: where it went).
        let last = (initialPage ?? Settings.store.string(forKey: Self.lastPageKey)).flatMap(SettingsPages.page(named:))
        if let i = tabs.tabViewItems.firstIndex(where: { $0.label == last }) { tabs.selectedTabViewItemIndex = i }
        tabs.onSelect = { item in
            Settings.store.set(item.label, forKey: Self.lastPageKey)
            // A page longer than the window says so: its scroller shows for a moment.
            (item.viewController?.view as? NSScrollView)?.flashScrollers()
        }

        let w = NSWindow(contentViewController: tabs)
        w.initialFirstResponder = nil
        // Titled after the page shown, as every page after the first is when chosen (the tab controller only retitles
        // on a change of page).
        w.title = tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex]?.label ?? "Settings"
        w.styleMask = [.titled, .closable, .resizable]
        // Wide enough for every page's toolbar item (narrower hides the last ones behind a » menu).
        w.setContentSize(NSSize(width: 760, height: 580))
        w.contentMinSize = NSSize(width: 560, height: 420)
        w.isReleasedWhenClosed = false
        self.builders = builders
        super.init(window: w)
        Self.window = w
        w.center()
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `page` (a current or an old page name) and scrolls its `section` heading to the top.
    func show(page: String, section: String? = nil) {
        guard let tabs = window?.contentViewController as? NSTabViewController, let name = SettingsPages.page(named: page),
            let i = tabs.tabViewItems.firstIndex(where: { $0.label == name })
        else { return }
        tabs.selectedTabViewItemIndex = i
        guard let section, let scroll = tabs.tabViewItems[i].viewController?.view as? NSScrollView, let doc = scroll.documentView,
            let heading = Self.heading(section, in: doc)
        else { return }
        doc.layoutSubtreeIfNeeded()
        let y = heading.convert(heading.bounds, to: doc).minY - 12
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, doc.frame.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// A section's heading (FormBuilder.section's label).
    static func heading(_ title: String, in view: NSView) -> NSTextField? {
        if let t = view as? NSTextField, t.identifier == FormBuilder.headingID, t.stringValue == title {
            return t
        }
        for v in view.subviews { if let found = heading(title, in: v) { return found } }
        return nil
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A scroll view whose bottom edge fades the content into the window while there is more below, so a row cut in half
/// reads as "scroll for more" (macOS 26's soft scroll edge, for a page under no bar).
final class FadingScrollView: NSScrollView {
    let fade = ScrollEdgeFade()
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(fade)
        contentView.postsBoundsChangedNotifications = true
        // Scrolled, or the page grown or shrunk (a row shown only for some choices).
        observers.append(
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) {
                [weak self] _ in self?.updateFade()
            })
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var documentView: NSView? {
        didSet {
            guard let doc = documentView else { return }
            observers.append(
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main) {
                    [weak self] _ in self?.updateFade()
                })
        }
    }

    /// The scroll view lays out its own subviews: the fade goes along the bottom, above the page.
    override func tile() {
        super.tile()
        let height = Tokens.Space.xxl
        fade.frame = CGRect(x: 0, y: isFlipped ? bounds.height - height : 0, width: bounds.width, height: height)
        if subviews.last !== fade { addSubview(fade, positioned: .above, relativeTo: nil) }
        updateFade()
    }

    /// Shown while the page goes on below the visible part.
    func updateFade() {
        guard let doc = documentView else { return }
        fade.isHidden = contentView.bounds.maxY >= doc.frame.maxY - 1
    }
}

/// The fade itself: the window's background, from clear at the top to opaque at the bottom.
final class ScrollEdgeFade: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [Theme.windowBackground.withAlphaComponent(0), Theme.windowBackground])?.draw(in: bounds, angle: -90)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
