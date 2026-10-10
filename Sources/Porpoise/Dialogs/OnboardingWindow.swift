import AppKit
import PorpoiseServices

/// First-run assistant: welcome, then every permission Porpoise needs (Full Disk Access, App Management, administrator
/// actions, Local Network), each detected live, then done. Shown before the first browser window; also reachable
/// later from Porpoise › Permissions…, which starts at the first permission that's still missing.
final class OnboardingWindowController: NSWindowController {
    static var shared: OnboardingWindowController?
    /// Set once the assistant has been finished (v2: with all four permissions).
    private static let doneKey = "onboardingDone2"

    /// Until it's been finished once, and while something is missing (PORPOISE_FORCE_ONBOARDING shows it in a test instance).
    static var shouldShow: Bool {
        if ProcessInfo.processInfo.environment["PORPOISE_FORCE_ONBOARDING"] != nil { return true }
        return !Settings.isTesting && !Settings.store.bool(forKey: doneKey) && !SystemIntegration.allPermissionsGranted
    }

    /// The helper comes first: its Full Disk Access switch then sits next to Porpoise's, granted in one visit.
    enum Step: Int, CaseIterable { case welcome, admin, fullDisk, apps, network, done }
    /// Porpoise › Permissions…: the first permission still missing.
    static var firstMissing: Step { Step.allCases.first { $0.page != nil && !($0.page!.granted()) } ?? .fullDisk }

    /// For tests: the shown step, or "none".
    static var debugStep: String { shared.map { "\($0.step)" } ?? "none" }

    /// `onFinish` runs once the assistant is closed (by finishing or skipping), e.g. to open the first window.
    static func show(at step: Step = .welcome, onFinish: (() -> Void)? = nil) {
        if shared == nil { shared = OnboardingWindowController() }
        // Opened again from the menu while the first-run assistant runs: keep its "open the first window".
        if let onFinish { shared?.onFinish = onFinish }
        shared?.go(to: step)
        NSApp.activate()
        shared?.showWindow(nil)
        shared?.window?.center()
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    private var onFinish: (() -> Void)?
    private var step: Step = .welcome
    private var timer: Timer?
    private let pages = NSView()
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let dots = NSStackView()
    // Permission page parts that change live.
    private let statusIcon = NSImageView()
    private let statusText = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private static let size = NSSize(width: 660, height: 490)

    init() {
        let w = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Welcome to Porpoise"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        buildChrome()
        // Closed with the close button: same as finishing without marking it done (asked again next launch).
        observers.append(
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.finish(markDone: false, closing: true)
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
        let bg = NSVisualEffectView(frame: content.bounds)
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.autoresizingMask = [.width, .height]
        content.addSubview(bg)
        pages.frame = CGRect(x: 0, y: 72, width: Self.size.width, height: Self.size.height - 72)
        content.addSubview(pages)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.controlSize = .large
        primary.target = self
        primary.action = #selector(primaryClicked)
        secondary.bezelStyle = .rounded
        secondary.controlSize = .large
        secondary.target = self
        secondary.action = #selector(secondaryClicked)
        for b in [primary, secondary] { content.addSubview(b) }
        dots.orientation = .horizontal
        dots.spacing = 8
        content.addSubview(dots)
    }

    private func layoutButtons() {
        primary.sizeToFit()
        secondary.sizeToFit()
        let pw = max(150, primary.frame.width + 24), sw = secondary.frame.width + 20
        primary.frame = CGRect(x: Self.size.width - 32 - pw, y: 24, width: pw, height: 32)
        secondary.frame = CGRect(x: primary.frame.minX - 12 - sw, y: 24, width: sw, height: 32)
        secondary.isHidden = secondary.title.isEmpty
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for s in Step.allCases {
            let d = NSView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
            d.wantsLayer = true
            d.layer?.cornerRadius = 4
            d.layer?.backgroundColor = (s == step ? Theme.accent : NSColor.tertiaryLabelColor).cgColor
            d.widthAnchor.constraint(equalToConstant: 8).isActive = true
            d.heightAnchor.constraint(equalToConstant: 8).isActive = true
            dots.addArrangedSubview(d)
        }
        dots.frame = CGRect(x: 32, y: 36, width: 8 * 16, height: 8)
    }

    private func go(to s: Step) {
        step = s
        pages.subviews.forEach { $0.removeFromSuperview() }
        timer?.invalidate()
        timer = nil
        switch s {
        case .welcome: buildWelcome()
        case .done: buildDone()
        default: if let p = s.page { buildPermission(p) }
        }
        layoutButtons()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        return l
    }

    private func centered(_ views: [NSView], spacing: CGFloat = 14) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        pages.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: pages.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: pages.centerYAnchor, constant: 10),
            stack.widthAnchor.constraint(equalToConstant: Self.size.width - 96),
        ])
        for v in views { (v as? NSTextField)?.preferredMaxLayoutWidth = Self.size.width - 96 }
    }

    // MARK: Pages

    private func buildWelcome() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true
        centered([
            icon,
            label("Welcome to Porpoise", size: 28, weight: .semibold),
            label(
                "A file manager for macOS inspired by KDE Dolphin: split view, a built-in terminal, tabs and panels.",
                size: 14, color: .secondaryLabelColor),
            label(
                "A few quick steps let Porpoise do everything Finder can, without asking you again later.",
                size: 14, color: .secondaryLabelColor),
        ])
        primary.title = "Continue"
        secondary.title = ""
    }

    /// A permission page: what it's for, how to allow it, and its live status.
    struct Page {
        /// What's allowed, e.g. "Full Disk Access" (the page is titled "Allow …").
        let name: String
        var title: String { "Allow " + name }
        let why: String
        /// Numbered instructions (Markdown); `tileRow` gets the draggable app icon.
        let steps: [String]
        var tileRow: Int? = nil
        let button: String
        let waiting: String
        let granted: () -> Bool
        let grantedText: String
        let request: () -> Void
    }

    private func buildPermission(_ p: Page) {
        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 10
        for (i, text) in p.steps.enumerated() {
            let row = stepRow(i + 1, text)
            if i == p.tileRow {
                let tile = AppDragTile()
                tile.widthAnchor.constraint(equalToConstant: 40).isActive = true
                tile.heightAnchor.constraint(equalToConstant: 40).isActive = true
                row.addArrangedSubview(tile)
            }
            steps.addArrangedSubview(row)
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        statusText.font = .systemFont(ofSize: 13, weight: .medium)
        let status = NSStackView(views: [spinner, statusIcon, statusText])
        status.spacing = 6
        centered(
            [label(p.title, size: 24, weight: .semibold), label(p.why, size: 13, color: .secondaryLabelColor), steps, status],
            spacing: 18)
        primary.title = p.button
        secondary.title = "Skip for Now"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkAccess() }
        checkAccess()
    }

    private func stepRow(_ n: Int, _ markdown: String) -> NSStackView {
        let badge = NSTextField(labelWithString: "\(n)")
        badge.font = .systemFont(ofSize: 12, weight: .bold)
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
        text.font = .systemFont(ofSize: 13)
        text.textColor = .labelColor
        let row = NSStackView(views: [badge, text])
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func buildDone() {
        let missing = Step.allCases.compactMap { s in s.page.flatMap { $0.granted() ? nil : $0.name } }
        let allSet = missing.isEmpty
        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: allSet ? "checkmark.circle.fill" : "info.circle.fill",
                accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 56, weight: .regular)
        icon.contentTintColor = allSet ? Theme.success : .secondaryLabelColor
        let tips = NSGridView(views: [
            [label("F3", size: 13, weight: .semibold), label("Split view", size: 13, color: .secondaryLabelColor)],
            [label("F4", size: 13, weight: .semibold), label("Terminal that follows your folder", size: 13, color: .secondaryLabelColor)],
            [label("⌘P", size: 13, weight: .semibold), label("Jump to the Places sidebar", size: 13, color: .secondaryLabelColor)],
            [label("⌘,", size: 13, weight: .semibold), label("Settings", size: 13, color: .secondaryLabelColor)],
        ])
        tips.rowSpacing = 6
        tips.columnSpacing = 14
        tips.column(at: 0).xPlacement = .trailing
        tips.column(at: 1).xPlacement = .leading
        // Only as wide as its content, so the stack centres it.
        for col in 0..<2 { tips.column(at: col).width = col == 0 ? 36 : 230 }
        tips.setContentHuggingPriority(.required, for: .horizontal)
        centered(
            [
                icon,
                label(allSet ? "You're all set" : "Almost there", size: 26, weight: .semibold),
                label(
                    allSet
                        ? "Porpoise can do everything Finder can, and won't ask you again."
                        : "Still to allow: \(missing.joined(separator: ", ")). You can do it any time from Porpoise › Permissions…",
                    size: 13, color: .secondaryLabelColor),
                tips,
            ], spacing: 16)
        primary.title = "Start Using Porpoise"
        secondary.title = ""
    }

    // MARK: Actions

    private func checkAccess() {
        guard let p = step.page else { return }
        let ok = p.granted()
        spinner.isHidden = ok
        statusIcon.isHidden = !ok
        statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        statusIcon.contentTintColor = Theme.success
        statusText.stringValue = ok ? p.grantedText : p.waiting
        statusText.textColor = ok ? Theme.success : .secondaryLabelColor
        if ok, primary.title != "Continue" {
            primary.title = "Continue"
            secondary.title = ""
            layoutButtons()
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    private func next() { go(to: Step(rawValue: step.rawValue + 1) ?? .done) }

    @objc private func primaryClicked() {
        switch step {
        case .welcome: next()
        case .done: finish(markDone: true)
        default:
            guard let p = step.page else { return }
            if p.granted() { next() } else { p.request() }
        }
    }

    @objc private func secondaryClicked() { if step.page != nil { next() } }

    private var finished = false

    private func finish(markDone: Bool, closing: Bool = false) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        if markDone { Settings.store.set(true, forKey: Self.doneKey) }
        let run = onFinish
        onFinish = nil
        if !closing { window?.close() }
        OnboardingWindowController.shared = nil
        run?()
    }
}

extension OnboardingWindowController.Step {
    /// The permission this step asks for (nil for welcome and done).
    var page: OnboardingWindowController.Page? {
        switch self {
        case .welcome, .done: return nil
        case .fullDisk:
            return .init(
                name: "Full Disk Access",
                why: "macOS keeps some folders private (the Trash, Library, other apps' files) until you allow it once.",
                steps: [
                    "Click **Open System Settings** below. It opens the Full Disk Access list.",
                    "Switch on **Porpoise** and **Porpoise Helper**. If Porpoise isn't listed, drag this icon into it:",
                    "Come back here. Porpoise notices on its own.",
                ],
                tileRow: 1, button: "Open System Settings", waiting: "Waiting for Full Disk Access…",
                granted: {
                    // The helper too, when it's installed (it does the work on system-owned items in the Trash).
                    PrivacyAccess.hasFullDiskAccess && (!PrivilegedHelper.isEnabled || PrivilegedHelper.hasFullDiskAccess == true)
                }, grantedText: "Full Disk Access is on.",
                request: {
                    // Make sure "Porpoise Helper" is in the list before it opens.
                    HelperSetup.openFullDiskAccess()
                })
        case .apps:
            return .init(
                name: "App Management",
                why: "Lets Porpoise move, rename and delete apps, as Finder does, without macOS blocking it.",
                steps: [
                    "Click **Open System Settings** below. It opens the App Management list.",
                    "Switch **Porpoise** on. If it isn't in the list, drag this icon into it:",
                    "Come back here. Porpoise notices on its own.",
                ],
                tileRow: 1, button: "Open System Settings", waiting: "Waiting for App Management…",
                granted: { PrivacyAccess.appManagementState == .allowed }, grantedText: "App Management is on.",
                request: { SystemIntegration.requestAppManagement() })
        case .admin:
            return .init(
                name: "Administrator Actions",
                why: "Some items belong to the system, such as App Store apps. Porpoise installs a small helper once, and "
                    + "then empties the Trash and deletes, moves and changes such items without asking, as Finder does.",
                steps: [
                    "Click **Install Helper** below.",
                    "macOS asks for your administrator password, once.",
                    "Done. In the next step you switch it on, next to Porpoise.",
                ],
                button: "Install Helper", waiting: "Not installed yet.",
                granted: { PrivilegedHelper.isEnabled }, grantedText: "Administrator actions are allowed.",
                request: { HelperSetup.install() })
        case .network:
            return .init(
                name: "Local Network",
                why: "Lets Porpoise find the file servers and shared folders on your network and show them under Network.",
                steps: [
                    "Click **Allow Network Access** below.",
                    "macOS asks whether Porpoise may find devices on your network: click **Allow**.",
                    "Answered Don't Allow before? Switch Porpoise on in the Local Network list that opens.",
                ],
                button: "Allow Network Access", waiting: "Waiting for Local Network access…",
                granted: { LocalNetworkAccess.shared.isAllowed }, grantedText: "Local Network access is on.",
                request: {
                    LocalNetworkAccess.shared.request { allowed in
                        if !allowed { SystemIntegration.openPrivacyPane("Privacy_LocalNetwork") }
                    }
                })
        }
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
