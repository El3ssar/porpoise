import AppKit
import PorpoiseServices

/// First-run welcome: one sheet over the first browser window, in two steps (welcome, then Full Disk Access, the one
/// permission worth asking for up front). Everything else is asked for the first time it's needed: the helper at the
/// first action on a system-owned item, App Management at the first app moved, Local Network at the first Network visit
/// (see `SystemIntegration.FirstNeed`). All of them are listed in Settings › System.
final class OnboardingWindowController: SecondaryWindowController {
    static var shared: OnboardingWindowController?
    /// Set once the welcome has been seen (finished, skipped or closed): Porpoise asks in context from then on.
    /// Kept from the earlier four-page assistant, so whoever finished that isn't welcomed again.
    static let doneKey = "onboardingDone2"

    /// Until it's been seen once, and while Full Disk Access is off (PORPOISE_FORCE_ONBOARDING shows it in a test instance).
    static var shouldShow: Bool {
        if TestEnvironment.forceOnboarding.isSet { return true }
        return !Settings.isTesting && !Settings.store.bool(forKey: doneKey) && !PrivacyAccess.hasFullDiskAccess
    }

    enum Step: Int, CaseIterable { case welcome, fullDisk }

    /// For tests: the shown step, or "none".
    static var debugStep: String { shared.map { "\($0.step)" } ?? "none" }

    /// Shows the welcome as a sheet on `window` (a standalone window when there is none).
    static func show(at step: Step = .welcome, on window: NSWindow? = nil) {
        if shared == nil { shared = OnboardingWindowController() }
        guard let shared, let sheet = shared.window else { return }
        shared.go(to: step)
        guard sheet.sheetParent == nil, !sheet.isVisible else { return }
        NSApp.activate()
        if let window, window.attachedSheet == nil {
            window.beginSheet(sheet)
        } else {
            shared.present()
            sheet.center()
        }
    }

    private(set) var step: Step = .welcome
    private var timer: Timer?
    private let pages = NSView()
    let primary = NSButton(title: "", target: nil, action: nil)
    let secondary = NSButton(title: "", target: nil, action: nil)
    let back = NSButton(title: "Back", target: nil, action: nil)
    let dots = NSStackView()
    // Permission page parts that change live.
    private let statusIcon = NSImageView()
    private let statusText = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    static let size = NSSize(width: 600, height: 440)
    /// Every page's content starts here (from the top), so nothing jumps between steps.
    static let contentTop: CGFloat = 44
    /// The column text and steps are set in, centred.
    static let column: CGFloat = 480

    init() {
        let w = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Welcome to Porpoise"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        buildChrome()
        // Closed with the close button (standalone): seen, as with Not Now.
        observers.append(
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.finish(closing: true)
            })
        // Coming back from System Settings: re-check at once.
        observers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.checkAccess()
            })
    }

    private var observers: [NSObjectProtocol] = []

    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Layout

    private func buildChrome() {
        guard let content = window?.contentView else { return }
        // The material of the browser window's sidebar, so the welcome looks like the app that follows.
        let bg = TintedMaterialView(material: .sidebar, tint: Theme.sidebarBackground, alpha: 0.70)
        bg.frame = content.bounds
        bg.autoresizingMask = [.width, .height]
        content.addSubview(bg)
        pages.frame = CGRect(x: 0, y: 92, width: Self.size.width, height: Self.size.height - 92)
        content.addSubview(pages)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryClicked)
        secondary.bezelStyle = .rounded
        secondary.keyEquivalent = "\u{1b}"
        secondary.target = self
        secondary.action = #selector(secondaryClicked)
        back.bezelStyle = .rounded
        back.target = self
        back.action = #selector(backClicked)
        for b in [primary, secondary, back] {
            b.controlSize = .large
            content.addSubview(b)
        }
        dots.orientation = .horizontal
        dots.spacing = 8
        dots.setAccessibilityElement(true)
        dots.setAccessibilityRole(.staticText)
        content.addSubview(dots)
    }

    /// Unselected pager dots: dark enough to see on the material (3:1 at least; secondaryLabelColor measured 3.05:1 in light).
    static let dotColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .secondaryLabelColor : NSColor.black.withAlphaComponent(0.55)
    }

    private func layoutButtons() {
        for b in [primary, secondary, back] { b.sizeToFit() }
        let pw = max(150, primary.frame.width + 24), sw = secondary.frame.width + 20, bw = back.frame.width + 20
        primary.frame = CGRect(x: Self.size.width - 32 - pw, y: 24, width: pw, height: 32)
        secondary.frame = CGRect(x: primary.frame.minX - 12 - sw, y: 24, width: sw, height: 32)
        back.frame = CGRect(x: 32, y: 24, width: bw, height: 32)
        secondary.isHidden = secondary.title.isEmpty
        back.isHidden = step == .welcome
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for s in Step.allCases {
            // The current page is an accent capsule, the others round dots.
            let width: CGFloat = s == step ? 16 : 8
            let d = PagerDot(color: s == step ? Theme.accent : Self.dotColor, width: width)
            d.widthAnchor.constraint(equalToConstant: width).isActive = true
            d.heightAnchor.constraint(equalToConstant: 8).isActive = true
            dots.addArrangedSubview(d)
        }
        dots.setAccessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        let dw = CGFloat(Step.allCases.count - 1) * 16 + 16
        // Centred above the buttons, clear of them on every page.
        dots.frame = CGRect(x: (Self.size.width - dw) / 2, y: 76, width: dw, height: 8)
    }

    func go(to s: Step) {
        step = s
        pages.subviews.forEach { $0.removeFromSuperview() }
        timer?.invalidate()
        timer = nil
        switch s {
        case .welcome: buildWelcome()
        case .fullDisk: buildFullDisk()
        }
        layoutButtons()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        l.preferredMaxLayoutWidth = Self.column
        return l
    }

    /// The page's content, from a fixed top, in one centred column.
    private func anchored(_ views: [NSView], spacing: CGFloat = 14) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        pages.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: pages.centerXAnchor),
            stack.topAnchor.constraint(equalTo: pages.topAnchor, constant: Self.contentTop),
            stack.widthAnchor.constraint(equalToConstant: Self.column),
        ])
    }

    // MARK: Pages

    private func buildWelcome() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        anchored([
            icon,
            label("Welcome to Porpoise", size: 26, weight: .semibold),
            label(
                "A fast file manager for your Mac: split view, tabs, a terminal that follows your folder, and your servers "
                    + "and cloud drives next to your disks.",
                size: 13, color: .secondaryLabelColor),
            label(
                "One permission helps from the start. Anything else, Porpoise asks for the first time you need it.",
                size: 13, color: .secondaryLabelColor),
        ])
        primary.title = "Continue"
        secondary.title = "Not Now"
    }

    /// Full Disk Access: what it's for, how to allow it (collapsed to one line once it's on), and its live status.
    private func buildFullDisk() {
        let granted = Self.fullDiskGranted()
        var views: [NSView] = [
            label("Allow Full Disk Access", size: 22, weight: .semibold),
            label(
                "macOS keeps some folders private (the Trash, Library, other apps' files) until you allow Porpoise once.",
                size: 13, color: .secondaryLabelColor),
        ]
        if !granted {
            let steps = NSStackView()
            steps.orientation = .vertical
            steps.alignment = .leading
            steps.spacing = 10
            let texts = [
                "Click **Open System Settings**. It opens the Full Disk Access list.",
                "Switch on **Porpoise**. If it isn't listed, drag this icon into the list:",
                "Come back here. Porpoise notices on its own.",
            ]
            for (i, text) in texts.enumerated() {
                let row = stepRow(i + 1, text)
                if i == 1 {
                    let tile = AppDragTile()
                    tile.widthAnchor.constraint(equalToConstant: 32).isActive = true
                    tile.heightAnchor.constraint(equalToConstant: 32).isActive = true
                    row.addArrangedSubview(tile)
                }
                steps.addArrangedSubview(row)
            }
            steps.widthAnchor.constraint(equalToConstant: Self.column).isActive = true
            views.append(steps)
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        statusText.font = .systemFont(ofSize: Tokens.FontSize.body, weight: .medium)
        let status = NSStackView(views: [spinner, statusIcon, statusText])
        status.spacing = 6
        views.append(status)
        views.append(
            label(
                "Administrator actions, App Management and Local Network are asked for when first needed. "
                    + "All of them are in Settings › System.",
                size: 11, color: .secondaryLabelColor))
        anchored(views, spacing: 18)
        secondary.title = granted ? "" : "Not Now"
        primary.title = granted ? "Start Using Porpoise" : "Open System Settings"
        if !granted { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkAccess() } }
        checkAccess(rebuild: false)
    }

    private func stepRow(_ n: Int, _ markdown: String) -> NSStackView {
        let badge = NSTextField(labelWithString: "\(n)")
        badge.font = .systemFont(ofSize: Tokens.FontSize.callout, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.drawsBackground = true
        badge.backgroundColor = Theme.accent
        badge.layer?.cornerRadius = 10
        badge.layer?.masksToBounds = true
        badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let text = NSTextField(labelWithAttributedString: (try? NSAttributedString(markdown: markdown)) ?? NSAttributedString(string: markdown))
        text.font = .systemFont(ofSize: Tokens.FontSize.body)
        text.textColor = .labelColor
        let row = NSStackView(views: [badge, text])
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    // MARK: Actions

    /// Porpoise's own switch, and the helper's when it's installed (it does the work on system-owned items).
    static var fullDiskGranted: () -> Bool = {
        PrivacyAccess.hasFullDiskAccess && (!PrivilegedHelper.isEnabled || PrivilegedHelper.hasFullDiskAccess == true)
    }

    private func checkAccess(rebuild: Bool = true) {
        guard step == .fullDisk else { return }
        let ok = Self.fullDiskGranted()
        // Just switched on: the instructions collapse to the one green line.
        if ok, rebuild, timer != nil {
            go(to: .fullDisk)
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            return
        }
        spinner.isHidden = ok
        statusIcon.isHidden = !ok
        statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        statusIcon.contentTintColor = Theme.success
        statusText.stringValue = ok ? "Full Disk Access is on." : "Waiting for Full Disk Access…"
        statusText.textColor = ok ? Theme.success : .secondaryLabelColor
    }

    @objc private func primaryClicked() {
        switch step {
        case .welcome: go(to: .fullDisk)
        case .fullDisk:
            // Make sure "Porpoise Helper" is in the list too, when it's installed.
            if Self.fullDiskGranted() { finish() } else { HelperSetup.openFullDiskAccess() }
        }
    }

    /// Not Now: closes, with nothing left to warn about; Porpoise asks again when a protected folder is opened.
    @objc private func secondaryClicked() { finish() }

    @objc private func backClicked() { go(to: .welcome) }

    private var finished = false

    func finish(closing: Bool = false) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        spinner.stopAnimation(nil)
        Settings.store.set(true, forKey: Self.doneKey)
        if let w = window, !closing {
            if let parent = w.sheetParent { parent.endSheet(w) } else { w.close() }
        }
        OnboardingWindowController.shared = nil
    }
}

/// One pager dot, drawn in its colour for the current look (a layer colour wouldn't follow light and dark).
private final class PagerDot: NSView {
    private let color: NSColor
    init(color: NSColor, width: CGFloat) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 8))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// The app's icon, draggable into System Settings' Full Disk Access list.
private final class AppDragTile: NSView, NSDraggingSource {
    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag Porpoise into the list"
    }

    required init?(coder: NSCoder) { fatalError() }

    private var icon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }

    override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
