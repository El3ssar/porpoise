import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

/// KPropertiesDialog.
final class PropertiesWindow: SecondaryWindowController, NSTextFieldDelegate {
    private let urls: [URL]
    private let knownItems: [FileItem]
    private(set) var localItems: [FileItem] = []
    private var localInformation: LocalInformation?
    private let informationCancellation = DiskCancellation()
    private let informationQueue = DispatchQueue(label: "app.porpoise.properties-info", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var pageSelector: NSView?
    private struct LocalInformation: Sendable {
        let items: [FileItem]
        let locked: Bool
        let hiddenExtension: Bool
        let comment: String
        let freeSpace: String?
    }
    private var nameField: NSTextField?
    let sizeLabel = NSTextField(labelWithString: "Calculating…")
    private var closeObserver: NSObjectProtocol?
    private var thumbnailObserver: NSObjectProtocol?
    /// Set when the window closes, so the background size count stops early.
    var sizeCount = DiskCancellation()
    let sizeQueue = DispatchQueue(label: "app.porpoise.properties-size", qos: .userInitiated, autoreleaseFrequency: .workItem)
    lazy var recalculateButton = NSButton(title: "Recalculate", target: self, action: #selector(recalculate(_:)))

    /// Local files, and one cloud item (Google Drive: its sharing instead of permissions). Other remote and virtual
    /// locations (sftp://, recent:/…) have no local path to inspect. `items`: what the view knows about them.
    static func show(urls: [URL], items: [FileItem] = []) {
        if let cloud = urls.first(where: PlacesModel.isCloud) {
            PropertiesWindow(cloud: cloud, item: items.first { $0.url == cloud }).present()
            return
        }
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { NSSound.beep(); return }
        PropertiesWindow(urls: urls, items: items).present()
    }

    /// The cloud item shown (nil: local items).
    let cloudItem: (url: URL, item: FileItem?)?

    convenience init(cloud url: URL, item: FileItem?) { self.init(urls: [url], cloud: (url, item)) }

    init(urls: [URL], cloud: (url: URL, item: FileItem?)? = nil, items: [FileItem] = []) {
        self.urls = urls
        knownItems = items
        cloudItem = cloud
        let w = PropertiesPanel(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 440, height: 660)
        w.backgroundColor = Theme.windowBackground
        w.isReleasedWhenClosed = false
        super.init(window: w)
        let name = cloud.map { $0.item?.name ?? $0.url.folderName } ?? urls[0].lastPathComponent
        w.title = urls.count == 1 ? "Properties for \(name)" : "Properties for \(urls.count) items"
        build()
        w.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sizeCount.cancel()
            self.informationCancellation.cancel()
            if self.cloudItem == nil { self.commitName() }
            if let o = self.closeObserver { NotificationCenter.default.removeObserver(o) }
            if let o = self.thumbnailObserver { NotificationCenter.default.removeObserver(o) }
        }
        if cloud == nil { readLocalInformation() }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { informationCancellation.cancel() }

    private var pages: [NSView] = []

    /// Read missing file metadata and volume information on a private queue. The window already exists, with
    /// a loading page; large selections do not make its initializer stat every path before it can appear.
    private func readLocalInformation() {
        let urls = urls, known = knownItems, cancellation = informationCancellation
        informationQueue.async { [weak self] in
            let byURL = Dictionary(known.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            var items: [FileItem] = []
            for url in urls {
                guard !cancellation.isCancelled else { return }
                let item = byURL[url] ?? autoreleasepool { FileItem.load(url) }
                if let item { items.append(item) }
            }
            guard !cancellation.isCancelled else { return }
            let locked = urls.allSatisfy { url in
                !cancellation.isCancelled && (try? url.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable) == true
            }
            let single = urls.count == 1
            let hidden = single && (try? urls[0].resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension) == true
            let comment = single ? FinderComment.read(urls[0]) : ""
            var freeSpace: String?
            if single, let volume = try? urls[0].resourceValues(forKeys: [.volumeURLKey]).volume,
                let values = try? volume.resourceValues(forKeys: [
                    .volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
                ]),
                let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity
            {
                freeSpace =
                    "\(FileFormat.size(free)) free of \(FileFormat.size(Int64(total))) on “\(values.volumeLocalizedName ?? volume.lastPathComponent)”"
            }
            let information = LocalInformation(items: items, locked: locked, hiddenExtension: hidden, comment: comment, freeSpace: freeSpace)
            DispatchQueue.main.async { [weak self] in
                guard let self, !cancellation.isCancelled else { return }
                self.localInformation = information
                self.localItems = information.items
                self.build()
            }
        }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        pages.forEach { $0.removeFromSuperview() }
        pageSelector?.removeFromSuperview()
        // Cloud items: one General page; Unix permissions mean nothing there, sharing is shown instead.
        let ready = cloudItem != nil || localInformation != nil
        let single = urls.count == 1 && cloudItem == nil && ready
        if let cloudItem {
            pages = [cloudGeneralView(cloudItem.url, item: cloudItem.item)]
        } else if ready {
            pages = [generalView()] + (single ? [permissionsView()] : [])
        } else {
            let loading = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            let label = label("Reading file information…")
            label.frame = CGRect(x: 20, y: 530, width: 360, height: 30)
            loading.addSubview(label)
            pages = [loading]
        }
        let seg = NSSegmentedControl(
            labels: single ? ["General", "Permissions"] : ["General"], trackingMode: .selectOne,
            target: self, action: #selector(switchPage(_:)))
        seg.selectedSegment = 0
        seg.sizeToFit()
        seg.frame.origin = CGPoint(x: (content.bounds.width - seg.frame.width) / 2, y: content.bounds.height - seg.frame.height - 14)
        seg.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.addSubview(seg)
        pageSelector = seg
        for (i, p) in pages.enumerated() {
            p.frame = CGRect(x: 20, y: 10, width: content.bounds.width - 40, height: seg.frame.minY - 20)
            p.autoresizingMask = [.width, .height]
            p.isHidden = i != 0
            content.addSubview(p)
        }
        // Async pages can arrive after the window became key, after the normal theme hook already ran.
        if let window { Theme.dressIfThemed(window) }
    }

    @objc private func switchPage(_ s: NSSegmentedControl) {
        for (i, p) in pages.enumerated() { p.isHidden = i != s.selectedSegment }
    }

    func row(_ k: String, _ v: NSView, y: inout CGFloat, in view: NSView) {
        let l = NSTextField(labelWithString: k)
        l.alignment = .right
        l.textColor = Theme.windowTextInactive
        l.font = .systemFont(ofSize: Tokens.FontSize.body)
        let valueWidth = view.bounds.width - 118
        var h = max(v.frame.height, 20)
        if let t = v as? NSTextField, t.maximumNumberOfLines != 1 {
            t.preferredMaxLayoutWidth = valueWidth
            h = max(20, ceil(t.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: valueWidth, height: 400)).height ?? 20))
        }
        let container = NSView(frame: CGRect(x: 0, y: y - h + 18, width: view.bounds.width, height: h))
        container.autoresizingMask = [.width, .minYMargin]
        for child in [l, v] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            l.widthAnchor.constraint(equalToConstant: 110),
            l.topAnchor.constraint(equalTo: container.topAnchor),
            l.heightAnchor.constraint(equalToConstant: 18),
            v.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 8),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view.addSubview(container)
        y -= h + 8
    }

    func label(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.isSelectable = true
        f.textColor = Theme.windowText
        f.font = .systemFont(ofSize: Tokens.FontSize.body)
        f.toolTip = s
        return f
    }

    private func pathLabel(_ path: String) -> NSTextField {
        let f = label(path)
        f.maximumNumberOfLines = 1
        f.lineBreakMode = .byTruncatingMiddle
        return f
    }

    /// The item's own picture (a photo, a PDF page), as Finder's Get Info shows it, once Thumbnails has made it.
    private func showThumbnail(of item: FileItem, in view: NSImageView) {
        guard Thumbnails.wantsPreview(item) else { return }
        if let image = Thumbnails.shared.thumbnail(for: item, size: 128, exact: true) {
            view.image = image
            return
        }
        thumbnailObserver = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) {
            [weak self, weak view] n in
            guard (n.object as? URL) == item.url, let view, let image = Thumbnails.shared.thumbnail(for: item, size: 128, exact: true)
            else { return }
            view.image = image
            if let o = self?.thumbnailObserver { NotificationCenter.default.removeObserver(o) }
            self?.thumbnailObserver = nil
        }
    }

    private func generalView() -> NSView {
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        var y: CGFloat = 572
        let items = localItems
        let icon = NSImageView(frame: CGRect(x: 20, y: y - 40, width: 64, height: 64))
        icon.autoresizingMask = [.minYMargin]
        icon.image = items.count == 1 ? Icons.shared.image(for: items[0], size: 64) : Icons.shared.image("document-multiple", size: 64)
        if items.count == 1 { showThumbnail(of: items[0], in: icon) }
        v.addSubview(icon)
        if items.count == 1 {
            let nf = NSTextField(string: items[0].name)
            nf.frame = CGRect(x: 100, y: y - 16, width: 290, height: 24)
            nf.autoresizingMask = [.width, .minYMargin]
            nf.delegate = self
            nameField = nf
            v.addSubview(nf)
        } else {
            let l = label("\(items.count) items")
            l.frame = CGRect(x: 100, y: y - 16, width: 290, height: 24)
            l.autoresizingMask = [.width, .minYMargin]
            v.addSubview(l)
        }
        y -= 70
        if items.count == 1 {
            let it = items[0]
            row("Type:", label(it.typeDescription), y: &y, in: v)
            if let mime = it.mimeType { row("MIME type:", label(mime), y: &y, in: v) }
            row("Location:", pathLabel(it.url.deletingLastPathComponent().path), y: &y, in: v)
            if let l = it.linkDestination { row("Points to:", pathLabel(l), y: &y, in: v) }
        }
        // Two lines only when there is a second to show (file and subfolder counts: a folder, or several items); a
        // file's size is one line, and a two-line row left a 44 pt gap before Free space.
        let twoLines = items.count > 1 || items.contains(where: \.isDirectory)
        let sizeRow = NSView(frame: CGRect(x: 0, y: 0, width: 282, height: twoLines ? 44 : 22))
        sizeLabel.font = .systemFont(ofSize: Tokens.FontSize.body)
        sizeLabel.textColor = Theme.windowText
        sizeLabel.maximumNumberOfLines = twoLines ? 2 : 1
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.isSelectable = true
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recalculateButton.controlSize = .small
        recalculateButton.font = .systemFont(ofSize: Tokens.FontSize.small)
        recalculateButton.bezelStyle = .rounded
        for child in [sizeLabel, recalculateButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            sizeRow.addSubview(child)
        }
        NSLayoutConstraint.activate([
            sizeLabel.leadingAnchor.constraint(equalTo: sizeRow.leadingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: sizeRow.topAnchor),
            sizeLabel.bottomAnchor.constraint(equalTo: sizeRow.bottomAnchor),
            recalculateButton.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 8),
            // A push button's bezel sits 1.5 pt further in than a popup's: this lines it up with Open with's (measured).
            recalculateButton.trailingAnchor.constraint(equalTo: sizeRow.trailingAnchor, constant: 1.5),
            recalculateButton.topAnchor.constraint(equalTo: sizeRow.topAnchor),
            recalculateButton.widthAnchor.constraint(equalToConstant: 86),
        ])
        row("Size:", sizeRow, y: &y, in: v)
        countSize()
        if let freeSpace = localInformation?.freeSpace { row("Free space:", label(freeSpace), y: &y, in: v) }
        y -= 8
        if items.count == 1 {
            let it = items[0]
            if let d = it.creationDate { row("Created:", label(FileFormat.longDate(d)), y: &y, in: v) }
            if let d = it.modificationDate { row("Modified:", label(FileFormat.longDate(d)), y: &y, in: v) }
            if let d = it.accessDate { row("Accessed:", label(FileFormat.longDate(d)), y: &y, in: v) }
            if !it.isBrowsableFolder && !it.isApplication && it.url.isFileURL {
                // Finder's "Open with" + "Change All…".
                let pop = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 270, height: 26), pullsDown: false)
                let def = NSWorkspace.shared.urlForApplication(toOpen: it.url)
                openWithApps = NSWorkspace.shared.urlsForApplications(toOpen: it.url).filter { $0.lastPathComponent != "Finder.app" }
                for a in openWithApps {
                    pop.addItem(withTitle: FileManager.default.displayName(atPath: a.path).replacingOccurrences(of: ".app", with: ""))
                    let icon = NSWorkspace.shared.icon(forFile: a.path); icon.size = NSSize(width: 16, height: 16)
                    pop.lastItem?.image = icon
                }
                if let d = def, let i = openWithApps.firstIndex(of: d) { pop.selectItem(at: i) }
                pop.target = self
                pop.action = #selector(openWithChanged(_:))
                if !openWithApps.isEmpty { row("Open with:", pop, y: &y, in: v) }
            }
        }
        if items.allSatisfy({ $0.url.isFileURL }) {
            y -= 4
            let tags = TagDotsView.view(for: urls) { [weak self] tag in self?.toggleTag(tag) }
            tags.frame.size = CGSize(width: 230, height: 30)
            row("Tags:", tags, y: &y, in: v)
            let locked = NSButton(checkboxWithTitle: "Locked", target: self, action: #selector(lockedChanged(_:)))
            locked.toolTip = "Prevents the item from being changed, renamed or moved to the Trash (Finder's Locked flag)"
            locked.state = localInformation?.locked == true ? .on : .off
            locked.frame.size = CGSize(width: 240, height: 20)
            row("", locked, y: &y, in: v)
            if items.count == 1 && !items[0].isBrowsableFolder && !items[0].fileExtension.isEmpty {
                let hide = NSButton(checkboxWithTitle: "Hide extension", target: self, action: #selector(hideExtChanged(_:)))
                hide.state = localInformation?.hiddenExtension == true ? .on : .off
                hide.frame.size = CGSize(width: 240, height: 20)
                row("", hide, y: &y, in: v)
            }
            if items.count == 1 {
                let c = NSTextField(string: localInformation?.comment ?? "")
                c.placeholderString = "Add comments"
                c.frame.size = CGSize(width: 270, height: 24)
                c.target = self
                c.action = #selector(commentChanged(_:))
                commentField = c
                row("Comments:", c, y: &y, in: v)
            }
        }
        return v
    }

    @objc private func recalculate(_ sender: Any?) {
        if let c = cloudItem { countCloudSize(c.url) } else { countSize() }
    }

    /// A private queue keeps filesystem work off both the main thread and GCD's shared worker pool.
    private func countSize() {
        sizeCount.cancel()
        let cancellation = DiskCancellation()
        sizeCount = cancellation
        let all = urls
        recalculateButton.isEnabled = false
        sizeLabel.stringValue = "Calculating…\n0 bytes, 0 items"
        sizeLabel.toolTip = sizeLabel.stringValue
        sizeQueue.async { [weak self] in
            let total = TreeMeasure.measure(all, cancellation: cancellation) { partial in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sizeCount === cancellation, !cancellation.isCancelled else { return }
                    let text = "Calculating…\n\(FileFormat.size(partial.bytes)), \(partial.items.formatted()) items"
                    self.sizeLabel.stringValue = text
                    self.sizeLabel.toolTip = text
                }
            }
            guard let total else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sizeCount === cancellation, !cancellation.isCancelled else { return }
                let sub = max(0, total.folders - (all.count == 1 && total.folders > 0 ? 1 : 0))
                var text = "\(FileFormat.size(total.bytes)) (\(total.bytes.formatted()) bytes)"
                if total.folders > 0 || all.count > 1 {
                    text +=
                        "\n\(total.files.formatted()) \(total.files == 1 ? "file" : "files"), \(sub.formatted()) \(sub == 1 ? "subfolder" : "subfolders")"
                }
                self.sizeLabel.stringValue = text
                self.sizeLabel.toolTip = text
                self.recalculateButton.isEnabled = true
            }
        }
    }

    private func permissionsView() -> NSView {
        // As tall as the General page, rows from the top (not floating in the middle of the window).
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        guard let it = localItems.first else { return v }
        var y: CGFloat = 550
        let groups = [("Owner:", 6), ("Group:", 3), ("Others:", 0)]
        var popups: [NSPopUpButton] = []
        for (title, shift) in groups {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let choices =
                it.isDirectory
                ? ["Forbidden", "Can View Content", "Can View & Modify Content"]
                : ["Forbidden", "Can Only View", "Can View & Modify"]
            popup.addItems(withTitles: choices)
            let bits = (it.posixPermissions >> shift) & 0o7
            popup.selectItem(at: bits & 0o2 != 0 ? 2 : (bits & 0o4 != 0 ? 1 : 0))
            popup.tag = shift
            popup.target = self
            popup.action = #selector(permChanged(_:))
            popup.frame.size = CGSize(width: 240, height: 26)
            row(title, popup, y: &y, in: v)
            popups.append(popup)
        }
        let exec = NSButton(
            checkboxWithTitle: it.isDirectory ? "Allow listing (execute)" : "Is executable", target: self, action: #selector(execChanged(_:)))
        exec.state = it.posixPermissions & 0o100 != 0 ? .on : .off
        exec.frame.size = CGSize(width: 240, height: 20)
        row("", exec, y: &y, in: v)
        y -= 10
        row("Ownership:", label("\(it.owner ?? "?") : \(it.group ?? "?")"), y: &y, in: v)
        modeLabel.stringValue = Self.modeText(it)
        row("Mode:", modeLabel, y: &y, in: v)
        permControls = (popups, exec)
        return v
    }

    private static func modeText(_ it: FileItem) -> String {
        FileFormat.permissions(it.posixPermissions, isDirectory: it.isDirectory) + "  (\(String(it.posixPermissions & 0o777, radix: 8)))"
    }

    private lazy var modeLabel = label("")
    private var permControls: (popups: [NSPopUpButton], exec: NSButton?) = ([], nil)

    /// Shows the permissions the item really has now (after a change, or a cancelled/failed one).
    private func refreshPermissions() {
        guard let it = FileItem.load(urls[0]) else { return }
        modeLabel.stringValue = Self.modeText(it)
        for p in permControls.popups {
            let bits = (it.posixPermissions >> p.tag) & 0o7
            p.selectItem(at: bits & 0o2 != 0 ? 2 : (bits & 0o4 != 0 ? 1 : 0))
        }
        permControls.exec?.state = it.posixPermissions & 0o100 != 0 ? .on : .off
    }

    private var openWithApps: [URL] = []
    private var commentField: NSTextField?

    @objc private func openWithChanged(_ p: NSPopUpButton) {
        guard let app = openWithApps[safe: p.indexOfSelectedItem], let t = FileItem.load(urls[0])?.utType else { return }
        let name = p.titleOfSelectedItem ?? app.lastPathComponent
        let a = NSAlert()
        a.messageText = "Do you want to open all documents like this one with “\(name)”?"
        a.informativeText = "This change will apply to all “\(t.localizedDescription ?? t.identifier)” documents."
        a.addButton(withTitle: "Change All")
        a.addButton(withTitle: "Open This File Now")
        a.addButton(withTitle: "Cancel")
        let urls = urls
        // The popup shows the app that really opens this kind of document: put it back unless the default changes.
        let revert = { [weak self, weak p] in
            guard let self, let p else { return }
            let def = NSWorkspace.shared.urlForApplication(toOpen: urls[0])
            if let d = def, let i = self.openWithApps.firstIndex(of: d) { p.selectItem(at: i) }
        }
        a.runSheet(for: window) { [weak self] r in
            switch r {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t) { err in
                    DispatchQueue.main.async {
                        revert()
                        if let err { NSAlert(error: err).runSheet(for: self?.window) { _ in } }
                    }
                }
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                revert()
            default:
                revert()
            }
        }
    }

    private func toggleTag(_ tag: String) {
        let all = urls.allSatisfy { FinderTags.read($0).contains { $0.name == tag } }
        for u in urls {
            var names = FinderTags.read(u).map(\.name).filter { $0 != tag }
            if !all { names.append(tag) }
            FinderTags.set(names, on: u)
        }
        FileOperationsController.notifyChanged(urls)
    }

    @objc private func lockedChanged(_ b: NSButton) {
        var failed: Error?
        for u in urls {
            var u = u
            var rv = URLResourceValues()
            rv.isUserImmutable = b.state == .on
            do { try u.setResourceValues(rv) } catch { failed = failed ?? error }
        }
        // Show what the items really are now (some may belong to someone else).
        b.state = urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable) == true }) ? .on : .off
        if let failed { NSAlert(error: failed).runSheet(for: window) { _ in } }
        FileOperationsController.notifyChanged(urls)
    }

    @objc private func hideExtChanged(_ b: NSButton) {
        var u = urls[0]
        var rv = URLResourceValues()
        rv.hasHiddenExtension = b.state == .on
        do { try u.setResourceValues(rv) } catch {
            b.state = b.state == .on ? .off : .on
            NSAlert(error: error).runSheet(for: window) { _ in }
        }
        FileOperationsController.notifyChanged(urls)
    }

    @objc private func commentChanged(_ f: NSTextField) { FinderComment.write(f.stringValue, to: urls[0]) }

    @objc private func permChanged(_ p: NSPopUpButton) {
        guard let it = FileItem.load(urls[0]) else { return }
        var mode = it.posixPermissions
        let shift = p.tag
        let exec = (mode >> shift) & 0o1
        let newBits: Int = [0, 0o4, 0o6][p.indexOfSelectedItem] | exec
        mode = (mode & ~(0o7 << shift)) | (newBits << shift)
        setMode(mode)
    }

    @objc private func execChanged(_ b: NSButton) {
        guard let it = FileItem.load(urls[0]) else { return }
        var mode = it.posixPermissions
        if b.state == .on { mode |= ((mode & 0o444) >> 2) } else { mode &= ~0o111 }
        setMode(mode)
    }

    /// chmod, asking to authenticate for items you don't own; then the view and this page show the result.
    private func setMode(_ mode: Int) {
        do { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: urls[0].path) } catch {
            FileOperationsController.shared.authorize(
                verb: "change the permissions of", items: [urls[0]],
                commands: [["/bin/chmod", "-h", "--", String(mode & 0o777, radix: 8), urls[0].path]], window: window)
        }
        refreshPermissions()
        FileOperationsController.notifyChanged(urls)
    }

    private func commitName() {
        if let c = commentField, c.stringValue != FinderComment.read(urls[0]) { FinderComment.write(c.stringValue, to: urls[0]) }
        guard let nf = nameField, urls.count == 1, nf.stringValue != urls[0].lastPathComponent, !nf.stringValue.isEmpty else { return }
        do {
            let new = try FileActions.rename(urls[0], to: nf.stringValue)
            FileOperationsController.shared.pushUndo(.renamed(from: urls[0], to: new))
            FileOperationsController.notifyChanged([urls[0], new])
        } catch {
            // The window is closing: tell the user the new name didn't stick.
            NSAlert(error: error).runSheet(for: nil) { _ in }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { window?.makeFirstResponder(nil); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { window?.performClose(nil); return true }
        return false
    }
}

/// Closing shortcuts stay local to Properties, including when another Porpoise window is open.
final class PropertiesPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            makeFirstResponder(nil)
        } else {
            performClose(sender)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .command {
            if [".", "w"].contains(event.charactersIgnoringModifiers ?? "") { performClose(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
