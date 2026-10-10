import AppKit
import PorpoiseCore
import PorpoiseServices

/// KPropertiesDialog.
final class PropertiesWindow: NSWindowController, NSTextFieldDelegate {
    private static var open: [PropertiesWindow] = []
    private let urls: [URL]
    private var nameField: NSTextField?
    private let sizeLabel = NSTextField(labelWithString: "Calculating…")
    private var closeObserver: NSObjectProtocol?
    /// Set when the window closes, so the background size count stops early.
    private let sizeCount = CancelFlag()

    /// Local files only: remote and virtual locations (sftp://, recent:/…) have no local path to inspect.
    static func show(urls: [URL]) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let w = PropertiesWindow(urls: urls)
        open.append(w)
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    init(urls: [URL]) {
        self.urls = urls
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.windowBackground
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.title = urls.count == 1 ? "Properties for \(urls[0].lastPathComponent)" : "Properties for \(urls.count) items"
        build()
        w.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sizeCount.cancel()
            self.commitName()
            if let o = self.closeObserver { NotificationCenter.default.removeObserver(o) }
            PropertiesWindow.open.removeAll { $0 === self }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var pages: [NSView] = []

    private func build() {
        guard let content = window?.contentView else { return }
        pages = [generalView()] + (urls.count == 1 ? [permissionsView()] : [])
        let seg = NSSegmentedControl(
            labels: urls.count == 1 ? ["General", "Permissions"] : ["General"], trackingMode: .selectOne,
            target: self, action: #selector(switchPage(_:)))
        seg.selectedSegment = 0
        seg.sizeToFit()
        seg.frame.origin = CGPoint(x: (content.bounds.width - seg.frame.width) / 2, y: content.bounds.height - seg.frame.height - 14)
        seg.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.addSubview(seg)
        for (i, p) in pages.enumerated() {
            p.frame = CGRect(x: 20, y: 10, width: content.bounds.width - 40, height: seg.frame.minY - 20)
            p.isHidden = i != 0
            content.addSubview(p)
        }
    }

    @objc private func switchPage(_ s: NSSegmentedControl) {
        for (i, p) in pages.enumerated() { p.isHidden = i != s.selectedSegment }
    }

    private func row(_ k: String, _ v: NSView, y: inout CGFloat, in view: NSView) {
        let l = NSTextField(labelWithString: k)
        l.alignment = .right
        l.textColor = Theme.windowTextInactive
        var h = max(v.frame.height, 20)
        if let t = v as? NSTextField {
            t.preferredMaxLayoutWidth = 270
            h = max(20, ceil(t.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: 270, height: 400)).height ?? 20))
        }
        // Rows grow downward: the label aligns with the value's first line.
        v.frame = CGRect(x: 118, y: y - h + 18, width: 270, height: h)
        l.frame = CGRect(x: 0, y: y, width: 110, height: 18)
        view.addSubview(l)
        view.addSubview(v)
        y -= h + 8
    }

    private func label(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.isSelectable = true
        f.textColor = Theme.windowText
        f.lineBreakMode = .byCharWrapping
        return f
    }

    private func generalView() -> NSView {
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        var y: CGFloat = 572
        let items = urls.compactMap(FileItem.load)
        let icon = NSImageView(frame: CGRect(x: 20, y: y - 40, width: 64, height: 64))
        icon.image = items.count == 1 ? Icons.shared.image(for: items[0], size: 64) : Icons.shared.image("document-multiple", size: 64)
        v.addSubview(icon)
        if items.count == 1 {
            let nf = NSTextField(string: items[0].name)
            nf.frame = CGRect(x: 100, y: y - 16, width: 290, height: 24)
            nf.delegate = self
            nameField = nf
            v.addSubview(nf)
        } else {
            let l = label("\(items.count) items")
            l.frame = CGRect(x: 100, y: y - 16, width: 290, height: 24)
            v.addSubview(l)
        }
        y -= 70
        if items.count == 1 {
            let it = items[0]
            row("Type:", label(it.typeDescription), y: &y, in: v)
            if let mime = it.mimeType { row("MIME type:", label(mime), y: &y, in: v) }
            row("Location:", label(it.url.deletingLastPathComponent().path), y: &y, in: v)
            if let l = it.linkDestination { row("Points to:", label(l), y: &y, in: v) }
        }
        row("Size:", sizeLabel, y: &y, in: v)
        countSize()
        sizeLabel.frame.size.height = items.count == 1 && !items[0].isBrowsableFolder ? 20 : 38
        if items.count == 1, let volURL = try? urls[0].resourceValues(forKeys: [.volumeURLKey]).volume,
            let vol = try? volURL.resourceValues(forKeys: [
                .volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
            ]),
            let free = vol.volumeAvailableCapacityForImportantUsage, let total = vol.volumeTotalCapacity
        {
            row(
                "Free space:",
                label(
                    "\(FileFormat.size(free)) free of \(FileFormat.size(Int64(total))) on “\(vol.volumeLocalizedName ?? volURL.lastPathComponent)”"),
                y: &y, in: v)
        }
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
            locked.state = urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable) == true }) ? .on : .off
            locked.frame.size = CGSize(width: 240, height: 20)
            row("", locked, y: &y, in: v)
            if items.count == 1 && !items[0].isBrowsableFolder && !items[0].fileExtension.isEmpty {
                let hide = NSButton(checkboxWithTitle: "Hide extension", target: self, action: #selector(hideExtChanged(_:)))
                hide.state = (try? urls[0].resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension) == true ? .on : .off
                hide.frame.size = CGSize(width: 240, height: 20)
                row("", hide, y: &y, in: v)
            }
            if items.count == 1 {
                let c = NSTextField(string: FinderComment.read(urls[0]))
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

    /// Total size, files and subfolders, counted in the background (Dolphin's KDirectorySizeJob).
    private func countSize() {
        let all = urls
        let cancel = sizeCount
        let label = sizeLabel
        DispatchQueue.global(qos: .userInitiated).async {
            var total: Int64 = 0
            var files = 0, dirs = 0
            for u in all {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                guard isDir.boolValue else {
                    files += 1
                    total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    continue
                }
                dirs += 1
                guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
                for case let c as URL in e {
                    if cancel.isCancelled { return }
                    let rv = try? c.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if rv?.isDirectory == true {
                        dirs += 1
                    } else {
                        files += 1
                        total += Int64(rv?.fileSize ?? 0)
                    }
                }
            }
            DispatchQueue.main.async {
                // A single folder doesn't count itself as a subfolder.
                let sub = max(0, dirs - (all.count == 1 && dirs > 0 ? 1 : 0))
                var text = "\(FileFormat.size(total)) (\(total.formatted()) bytes)"
                if dirs > 0 || all.count > 1 {
                    text += "\n\(files == 1 ? "1 file" : "\(files) files"), \(sub == 1 ? "1 subfolder" : "\(sub) subfolders")"
                }
                label.stringValue = text
            }
        }
    }

    private func permissionsView() -> NSView {
        // As tall as the General page, rows from the top (not floating in the middle of the window).
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        guard let it = FileItem.load(urls[0]) else { return v }
        var y: CGFloat = 550
        let groups = [("Owner:", 6), ("Group:", 3), ("Others:", 0)]
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
        permControls = (v.subviews.compactMap { $0 as? NSPopUpButton }, exec)
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
                commands: [["/bin/chmod", "--", String(mode & 0o7777, radix: 8), urls[0].path]], window: window)
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
        if sel == #selector(NSResponder.insertNewline(_:)) { window?.performClose(nil); return true }
        return false
    }
}

/// A thread-safe "stop" flag for background work tied to a window.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
