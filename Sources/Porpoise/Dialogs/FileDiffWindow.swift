import AppKit
import PorpoiseCore
import PorpoiseServices
import UniformTypeIdentifiers

/// Document-like comparison windows, independent of the browser's selection and lifecycle.
final class FileDiffWindow: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    private static var open: [FileDiffWindow] = []
    private static let queue = DispatchQueue(label: "app.porpoise.file-diff", qos: .userInitiated, attributes: .concurrent)
    static var current: FileDiffWindow? { (NSApp.keyWindow?.windowController as? FileDiffWindow) ?? open.last }
    static func present(left: URL, right: URL) {
        if let path = Settings.store.string(forKey: "fileDiff.defaultApp"), FileManager.default.fileExists(atPath: path) {
            FileDiffExternalTools.open(URL(fileURLWithPath: path), left: left, right: right) { error in NSAlert(error: error).runModal() }; return
        }
        let controller = FileDiffWindow(left: left, right: right); open.append(controller); controller.showWindow(nil);
        controller.window?.makeKeyAndOrderFront(nil)
    }

    let leftURL: URL, rightURL: URL
    private let root = FileDiffRoot()
    private let header = NSView(), footer = NSView(), body = NSView()
    private let leftCapsule = GlassGroup(), rightCapsule = GlassGroup(), navigation = GlassGroup()
    private let previous = ClosureButton(title: "‹") { _ in }, next = ClosureButton(title: "›") { _ in }
    private let openWith = NSPopUpButton(frame: .zero, pullsDown: true)
    private let externalCapsule = GlassGroup()
    private let viewSwitch = NSSegmentedControl(labels: ["Text", "Image", "Info"], trackingMode: .selectOne, target: nil, action: nil)
    private let textMode = NSSegmentedControl(labels: ["Side by Side", "Inline"], trackingMode: .selectOne, target: nil, action: nil)
    private let imageMode = NSSegmentedControl(
        labels: ["Side by Side", "Onion Skin", "Difference"], trackingMode: .selectOne, target: nil, action: nil)
    private let ignore = ClosureButton(checkboxWithTitle: "Ignore whitespace") { _ in }
    private let blend = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let facts = NSTextField(labelWithString: "Reading files…")
    private let loading = NSProgressIndicator()
    private let textScroll = NSScrollView(), textCanvas = FileDiffTextView(frame: .zero), imageCanvas = FileDiffImageView()
    private let infoScroll = NSScrollView(), infoStack = NSStackView()
    private let infoDocument = NSView()
    private let message = NSTextField(labelWithString: "")
    private let undo = UndoManager()
    private var token = DiskCancellation()
    private var generation = 0
    private var leftFile: ComparedFile?, rightFile: ComparedFile?
    private var leftText: String?, rightText: String?
    private var savedLeft: String?, savedRight: String?
    private var images: FileDiffImages?
    private var offset: UInt64?
    private var ready = false
    private var focused = 0
    private var mode = 0
    private var hashes: [String?] = [nil, nil]
    private var hashBusy = Set<Int>()
    private var observers: [NSObjectProtocol] = []
    private var busy = true
    private var lineEnding = "LF"
    private var dirty: Bool { leftText != savedLeft || rightText != savedRight }
    override var undoManager: UndoManager? { undo }

    /// AppKit does not automatically protect NSWindowController documents when the app quits.
    static func confirmQuitIfNeeded(_ completion: @escaping (Bool) -> Void) -> Bool {
        let dirty = open.filter { $0.dirty }
        guard !dirty.isEmpty else { return false }
        func ask(_ remaining: ArraySlice<FileDiffWindow>) {
            guard let first = remaining.first, let window = first.window else { completion(true); return }
            let alert = NSAlert();
            alert.messageText =
                "Save changes to \(first.leftText != first.savedLeft ? first.leftURL.lastPathComponent : first.rightURL.lastPathComponent)?"
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Don’t Save")
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    first.save(completion: { ask(remaining.dropFirst()) }, failed: { completion(false) })
                } else if response == .alertThirdButtonReturn {
                    ask(remaining.dropFirst())
                } else {
                    completion(false)
                }
            }
        }
        ask(dirty[...]); return true
    }

    init(left: URL, right: URL) {
        leftURL = left; rightURL = right
        let w = FileDiffNativeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Compare Files — \(left.lastPathComponent)"; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false; w.isRestorable = false; w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 640, height: 420); w.backgroundColor = Theme.windowBackground; w.delegate = self
        w.contentView = root; root.owner = self; setup(); w.center(); read()
        Theme.whenChanged(self) { [weak self] in self?.refreshLook() }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func setup() {
        for v in [header, body, footer] { root.addSubview(v) }
        for v in [leftCapsule, navigation, rightCapsule, externalCapsule] { header.addSubview(v) }
        addFile(leftURL, to: leftCapsule); addFile(rightURL, to: rightCapsule)
        for b in [previous, next] { b.isBordered = false; b.font = .systemFont(ofSize: 23); navigation.content.addSubview(b) }
        previous.setAccessibilityLabel("Previous Change"); next.setAccessibilityLabel("Next Change")
        previous.handler = { [weak self] _ in self?.move(-1) }; next.handler = { [weak self] _ in self?.move(1) }
        let menu = NSMenu(); menu.addItem(withTitle: "Open With ⌄", action: nil, keyEquivalent: ""); menu.delegate = self; openWith.menu = menu;
        openWith.isBordered = false; openWith.font = .systemFont(ofSize: 13)
        (openWith.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        externalCapsule.content.addSubview(openWith)
        for c in [viewSwitch, textMode, imageMode] {
            c.controlSize = .small; c.target = self; c.action = #selector(controlChanged(_:)); c.selectedSegment = 0
        }
        viewSwitch.setAccessibilityLabel("Comparison View"); textMode.setAccessibilityLabel("Text Layout");
        imageMode.setAccessibilityLabel("Image Comparison Mode")
        for v in [viewSwitch, textMode, imageMode, blend, facts, ignore] { footer.addSubview(v) }
        facts.font = .systemFont(ofSize: 11); facts.textColor = Theme.windowTextInactive; facts.lineBreakMode = .byTruncatingTail
        blend.target = self; blend.action = #selector(blendChanged); blend.setAccessibilityLabel("Onion Skin Opacity")
        ignore.font = .systemFont(ofSize: 11); ignore.handler = { [weak self] _ in self?.rediff() }
        textScroll.documentView = textCanvas; textScroll.hasVerticalScroller = true; textScroll.autohidesScrollers = true;
        textScroll.drawsBackground = false
        textCanvas.copyChange = { [weak self] change, toRight in self?.copyChange(change, toRight: toRight) };
        textCanvas.jump = { [weak self] i in self?.focus(i) }
        textScroll.contentView.postsBoundsChangedNotifications = true
        observers.append(
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: textScroll.contentView, queue: .main) {
                [weak self] _ in
                self?.textCanvas.needsDisplay = true; self?.textCanvas.updateCopyButtons()
            })
        infoStack.orientation = .vertical; infoStack.alignment = .leading; infoStack.spacing = 0
        infoDocument.addSubview(infoStack); infoScroll.documentView = infoDocument; infoScroll.hasVerticalScroller = true;
        infoScroll.autohidesScrollers = true; infoScroll.drawsBackground = false
        for v in [textScroll, imageCanvas, infoScroll, message, loading] { body.addSubview(v) }
        message.font = .systemFont(ofSize: 17, weight: .semibold); message.textColor = Theme.viewText; message.alignment = .center;
        message.maximumNumberOfLines = 2
        loading.style = .spinning; loading.controlSize = .small; loading.startAnimation(nil)
        previous.nextKeyView = next; next.nextKeyView = openWith
        openWith.nextKeyView = viewSwitch; viewSwitch.nextKeyView = textMode; textMode.nextKeyView = ignore
        updateVisibility()
    }
    private func addFile(_ url: URL, to capsule: GlassGroup) {
        let icon = NSImageView(); icon.image = Icons.shared.image(for: FileItem(url: url, name: url.lastPathComponent, isDirectory: false), size: 18);
        icon.frame = NSRect(x: 12, y: 8, width: 18, height: 18)
        let name = NSTextField(labelWithString: url.lastPathComponent); name.font = .systemFont(ofSize: 13, weight: .semibold);
        name.textColor = Theme.windowText; name.lineBreakMode = .byTruncatingMiddle
        let path = NSTextField(labelWithString: url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: " › "));
        path.font = .systemFont(ofSize: 12); path.textColor = Theme.windowTextInactive; path.lineBreakMode = .byTruncatingHead
        capsule.content.addSubview(icon); capsule.content.addSubview(name); capsule.content.addSubview(path); capsule.toolTip = url.path
        capsule.setAccessibilityElement(true); capsule.setAccessibilityRole(.group); capsule.setAccessibilityLabel(url.path)
    }
    func layoutContents() {
        let w = root.bounds.width, h = root.bounds.height
        header.frame = NSRect(x: 0, y: 0, width: w, height: 52); footer.frame = NSRect(x: 0, y: h - 32, width: w, height: 32);
        body.frame = NSRect(x: 0, y: 52, width: w, height: max(0, h - 84))
        let external: CGFloat = w < 800 ? 98 : 112, nav: CGFloat = 66, margin: CGFloat = 8
        let seam = (w - 8) / 2
        navigation.frame = NSRect(x: seam - nav / 2, y: 9, width: nav, height: 34)
        leftCapsule.frame = NSRect(x: 82, y: 9, width: navigation.frame.minX - 90, height: 34)
        externalCapsule.frame = NSRect(x: w - external - 12, y: 9, width: external, height: 34)
        rightCapsule.frame = NSRect(
            x: navigation.frame.maxX + margin, y: 9, width: externalCapsule.frame.minX - navigation.frame.maxX - margin * 2, height: 34)
        openWith.frame = NSRect(x: 2, y: 0, width: external - 4, height: 34)
        previous.frame = NSRect(x: 2, y: 1, width: 30, height: 32); next.frame = NSRect(x: 34, y: 1, width: 30, height: 32)
        for capsule in [leftCapsule, rightCapsule] {
            let labels = capsule.content.subviews.compactMap { $0 as? NSTextField }
            if labels.count == 2 {
                let cap = capsule.frame.width
                let nameW = min((labels[0].stringValue as NSString).size(withAttributes: [.font: labels[0].font!]).width + 4, max(20, cap - 65))
                labels[0].frame = NSRect(x: 38, y: 9, width: max(20, nameW), height: 18)
                labels[1].frame = NSRect(x: 44 + nameW, y: 10, width: max(0, cap - 56 - nameW), height: 16)
            }
        }
        viewSwitch.frame = NSRect(x: 12, y: 5, width: 144, height: 23)
        let controlWidth: CGFloat = mode == 1 ? (w < 850 ? 242 : 280) : 154
        textMode.frame = NSRect(x: 166, y: 5, width: controlWidth, height: 23); imageMode.frame = textMode.frame
        ignore.frame = NSRect(x: w - 143, y: 7, width: 135, height: 20)
        let x: CGFloat = mode == 2 ? 170 : 174 + controlWidth
        facts.frame = NSRect(x: x, y: 9, width: max(0, w - x - (mode == 0 ? 151 : 14)), height: 16)
        blend.frame = NSRect(x: w - 130, y: 5, width: 118, height: 24)
        if mode == 1 && imageMode.selectedSegment == 1 { facts.frame.size.width = max(0, w - x - 145) }
        for v in [textScroll, imageCanvas, infoScroll] { v.frame = body.bounds }
        resizeText()
        let infoWidth = min(780, max(550, w - 80));
        infoDocument.frame = NSRect(x: 0, y: 0, width: w, height: max(body.bounds.height, infoStack.fittingSize.height + 56));
        infoStack.frame = NSRect(x: (w - infoWidth) / 2, y: 0, width: infoWidth, height: max(body.bounds.height, infoStack.fittingSize.height + 56))
        for row in infoStack.arrangedSubviews { row.setFrameSize(NSSize(width: infoWidth, height: row.frame.height)) }
        message.frame = NSRect(x: 30, y: body.bounds.height / 2 - 12, width: w - 60, height: 52)
        loading.frame = NSRect(x: w / 2 - 8, y: body.bounds.height / 2 + 28, width: 16, height: 16)
    }
    private func resizeText() {
        textCanvas.frame = NSRect(
            x: 0, y: 0, width: textScroll.contentSize.width,
            height: max(textScroll.contentSize.height, CGFloat(textCanvas.presentation?.rows.count ?? 0) * 18 + 24));
        textCanvas.needsDisplay = true; textCanvas.updateCopyButtons()
    }
    private func refreshLook() {
        window?.backgroundColor = Theme.windowBackground; root.needsDisplay = true; textCanvas.needsDisplay = true; imageCanvas.needsDisplay = true;
        if ready { buildInfo() }
    }
    private func read() {
        let token = self.token, left = leftURL, right = rightURL
        let isImage = [left, right].allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        Self.queue.async { [weak self] in
            do {
                let binaryExtensions: Set<String> = [
                    "numbers", "pages", "key", "pdf", "zip", "gz", "dmg", "mp4", "mov", "mp3", "sqlite", "db", "exe",
                ]
                let a = try ComparedFile(url: left, readText: !isImage && !binaryExtensions.contains(left.pathExtension.lowercased())),
                    b = try ComparedFile(url: right, readText: !isImage && !binaryExtensions.contains(right.pathExtension.lowercased()))
                let offset = try FileComparison.firstDifference(left, right, cancellation: token)
                let images = isImage ? try FileDiffImages.load(left, right) : nil
                try token.check()
                DispatchQueue.main.async {
                    guard let self, !token.isCancelled else { return }
                    self.leftFile = a; self.rightFile = b; self.leftText = a.text; self.rightText = b.text; self.savedLeft = a.text;
                    self.savedRight = b.text
                    self.lineEnding = a.text?.prefix(8192).contains("\r\n") == true ? "CRLF" : "LF"
                    self.offset = offset; self.images = images; self.imageCanvas.images = images; self.ready = true
                    self.mode = images != nil ? 1 : (a.text != nil && b.text != nil ? 0 : 2)
                    self.viewSwitch.selectedSegment = self.mode; self.viewSwitch.setEnabled(a.text != nil && b.text != nil, forSegment: 0);
                    self.viewSwitch.setEnabled(images != nil, forSegment: 1)
                    self.buildInfo(); self.rediff()
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.fail(error) } }
        }
    }
    private func fail(_ error: Error) {
        busy = false; facts.stringValue = error.localizedDescription; message.stringValue = "Couldn’t compare these files"; message.isHidden = false;
        loading.stopAnimation(nil); loading.isHidden = true
    }
    private func rediff() {
        guard ready else { return }
        generation += 1; let version = generation
        guard let a = leftText, let b = rightText else { busy = false; updateVisibility(); return }
        busy = true; facts.stringValue = "Comparing text…"; loading.startAnimation(nil); loading.isHidden = false
        let whitespace = ignore.state == .on, inline = textMode.selectedSegment == 1
        Self.queue.async { [weak self] in
            let difference = TextDifference(left: a, right: b, ignoreWhitespace: whitespace)
            let presentation = FileDiffPresentation(difference, inline: inline)
            DispatchQueue.main.async {
                guard let self, self.generation == version, !self.token.isCancelled else { return }
                self.textCanvas.presentation = presentation; self.textCanvas.inline = inline; self.busy = false
                self.focused = min(self.focused, max(0, presentation.starts.count - 1)); self.textCanvas.focused = self.focused;
                self.textCanvas.updateCopyButtons()
                self.resizeText(); self.updateVisibility()
            }
        }
    }
    private func updateVisibility() {
        textScroll.isHidden = mode != 0; imageCanvas.isHidden = mode != 1; infoScroll.isHidden = mode != 2
        textMode.isHidden = mode != 0; imageMode.isHidden = mode != 1; blend.isHidden = mode != 1 || imageMode.selectedSegment != 1;
        ignore.isHidden = mode != 0
        let count = textCanvas.presentation?.difference.changes.count ?? 0
        previous.isEnabled = mode == 0 && count > 0 && !busy; next.isEnabled = previous.isEnabled
        loading.isHidden = !busy; if !busy { loading.stopAnimation(nil) }
        let identical = mode == 0 && !busy && ready && count == 0
        message.isHidden = !identical; message.stringValue = "✓  The files are identical"
        if identical, let a = leftFile, let b = rightFile, a.modified != b.modified {
            message.stringValue += "\nMetadata differs: modified date"
        }
        textScroll.isHidden = mode != 0 || identical
        if !busy {
            if mode == 0 {
                facts.stringValue =
                    "\(count > 0 ? "\(focused + 1) of " : "")\(count) changes · UTF-8 · \(lineEnding)"
            } else if mode == 1, let images {
                facts.stringValue =
                    imageMode.selectedSegment == 2
                    ? String(format: "Changed pixels: %.2f %%%@", images.changedPercent ?? 0, images.sampled ? " (sampled)" : "")
                    : "\(images.left.width) × \(images.left.height) vs \(images.right.width) × \(images.right.height)"
            } else {
                facts.stringValue = "\(propertyRows().filter { $0.1 != $0.2 }.count) properties differ"
            }
        }
        root.needsLayout = true
    }
    @objc private func controlChanged(_ sender: NSSegmentedControl) {
        if sender === viewSwitch {
            mode = sender.selectedSegment; updateVisibility()
        } else if sender === textMode {
            rediff()
        } else {
            imageCanvas.mode = sender.selectedSegment; updateVisibility()
        }
    }
    @objc private func blendChanged() { imageCanvas.opacity = CGFloat(blend.doubleValue) }
    func move(_ delta: Int) { let n = textCanvas.presentation?.starts.count ?? 0; guard n > 0 else { return }; focus((focused + delta + n) % n) }
    func focus(_ change: Int) {
        guard let p = textCanvas.presentation, p.starts.indices.contains(change) else { return }
        focused = change; textCanvas.focused = change; textCanvas.updateCopyButtons()
        textCanvas.scrollToVisible(NSRect(x: 0, y: max(0, CGFloat(p.starts[change]) * 18 - 80), width: 1, height: 180));
        textCanvas.needsDisplay = true
        let c = p.difference.changes[change]
        let speech =
            "Change \(change + 1) of \(p.starts.count). Left line \(c.left.lowerBound + 1), \(c.left.count) lines. Right line \(c.right.lowerBound + 1), \(c.right.count) lines."
        let leftExcerpt = p.difference.left[c.left].prefix(3).map { String($0.prefix(500)) }.joined(),
            rightExcerpt = p.difference.right[c.right].prefix(3).map { String($0.prefix(500)) }.joined()
        textCanvas.setAccessibilityValue(speech + " Left: " + leftExcerpt + " Right: " + rightExcerpt)
        NSAccessibility.post(element: textCanvas, notification: .valueChanged)
    }
    func copyChange(_ index: Int, toRight: Bool) {
        guard !busy, let d = textCanvas.presentation?.difference else { return }
        busy = true; updateVisibility()
        Self.queue.async { [weak self] in
            let new = d.copying(index, toRight: toRight)
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                guard let new else { self.updateVisibility(); return }
                self.replaceText(new, right: toRight); self.undo.setActionName("Copy Change \(toRight ? "Right" : "Left")")
            }
        }
    }

    private func replaceText(_ text: String, right: Bool) {
        let old = (right ? rightText : leftText) ?? ""
        undo.registerUndo(withTarget: self) { target in target.replaceText(old, right: right) }
        if right { rightText = text } else { leftText = text }
        window?.isDocumentEdited = dirty; rediff()
    }
    @objc func undoFileOperation(_ sender: Any?) { undo.undo() }
    @objc func redoFileOperation(_ sender: Any?) { undo.redo() }
    @objc func saveDocument(_ sender: Any?) { save(completion: nil) }
    private func save(completion: (() -> Void)?, failed: (() -> Void)? = nil) {
        guard !busy else { failed?(); return }
        let a = leftText, b = rightText, sa = savedLeft, sb = savedRight, left = leftURL, right = rightURL
        busy = true; facts.stringValue = "Saving…"; updateVisibility()
        Self.queue.async { [weak self] in
            var writtenLeft = false, writtenRight = false
            do {
                // Refuse to overwrite a file changed outside this comparison since it was opened/saved.
                if a != sa, let sa {
                    guard try String(contentsOf: left, encoding: .utf8) == sa else { throw FileDiffSaveError.changed(left.lastPathComponent) }
                }
                if b != sb, let sb {
                    guard try String(contentsOf: right, encoding: .utf8) == sb else { throw FileDiffSaveError.changed(right.lastPathComponent) }
                }
                if a != sa, let a { try a.write(to: left, atomically: true, encoding: .utf8); writtenLeft = true }
                if b != sb, let b { try b.write(to: right, atomically: true, encoding: .utf8); writtenRight = true }
                let leftMetadata = try ComparedFile(url: left, readText: false), rightMetadata = try ComparedFile(url: right, readText: false)
                let offset = try FileComparison.firstDifference(left, right)
                DispatchQueue.main.async {
                    guard let self else { return }; self.leftFile = leftMetadata; self.rightFile = rightMetadata; self.offset = offset;
                    self.hashes = [nil, nil]; self.buildInfo(); self.savedLeft = a; self.savedRight = b; self.busy = false;
                    self.window?.isDocumentEdited = false;
                    self.updateVisibility(); completion?()
                }
            } catch {
                let baselineLeft = writtenLeft ? a : sa, baselineRight = writtenRight ? b : sb
                DispatchQueue.main.async { [weak self] in
                    self?.savedLeft = baselineLeft; self?.savedRight = baselineRight; self?.window?.isDocumentEdited = self?.dirty ?? false
                    self?.busy = false; self?.showError(error); self?.updateVisibility(); failed?()
                }
            }
        }
    }
    private func showError(_ error: Error) { let alert = NSAlert(error: error); alert.beginSheetModal(for: window!) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let a = NSAlert(); a.messageText = "Save changes to \(leftText != savedLeft ? leftURL.lastPathComponent : rightURL.lastPathComponent)?"
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Don’t Save")
        a.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.save { self?.window?.close() }
            } else if response == .alertThirdButtonReturn {
                self?.window?.close()
            }
        }; return false
    }
    func windowWillClose(_ notification: Notification) {
        token.cancel(); observers.forEach(NotificationCenter.default.removeObserver); Self.open.removeAll { $0 === self }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems(); menu.addItem(withTitle: "Open With ⌄", action: nil, keyEquivalent: "")
        for tool in FileDiffExternalTools.installed {
            let item = NSMenuItem(title: tool.name, action: #selector(openExternal(_:)), keyEquivalent: ""); item.target = self;
            item.representedObject = tool.url; menu.addItem(item)
        }
        if menu.items.count == 1 {
            let item = NSMenuItem(title: "No compare apps found", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
        }
        menu.addItem(.separator()); let choose = NSMenuItem(title: "Choose Default App…", action: #selector(chooseExternal), keyEquivalent: "");
        choose.target = self; menu.addItem(choose)
    }
    @objc private func openExternal(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        FileDiffExternalTools.open(app, left: leftURL, right: rightURL) { [weak self] error in self?.showError(error) }
    }
    @objc private func chooseExternal() { FileDiffExternalTools.chooseDefault(window: window) {} }
    func debug(_ command: String) {
        let parts = command.split(separator: " ").map(String.init)
        guard let op = parts.first else { return }
        switch op {
        case "inline": textMode.selectedSegment = 1; rediff()
        case "sidebyside": textMode.selectedSegment = 0; imageMode.selectedSegment = 0; imageCanvas.mode = 0; rediff()
        case "image", "info", "text": mode = op == "image" ? 1 : (op == "info" ? 2 : 0); viewSwitch.selectedSegment = mode; updateVisibility()
        case "onion", "difference":
            mode = 1; viewSwitch.selectedSegment = 1; imageMode.selectedSegment = op == "onion" ? 1 : 2; imageCanvas.mode = imageMode.selectedSegment;
            updateVisibility()
        case "front":
            NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        case "state":
            if parts.count > 1 {
                let state: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier, "title": window?.title ?? "", "windowNumber": window?.windowNumber ?? 0,
                    "active": NSApp.isActive, "key": window?.isKeyWindow ?? false, "busy": busy, "mode": mode,
                    "changes": textCanvas.presentation?.starts.count ?? 0, "dirty": dirty,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) {
                    try? data.write(to: URL(fileURLWithPath: parts[1]))
                }
            }
        case "next": move(1)
        case "copyright": copyChange(focused, toRight: true)
        case "copyleft": copyChange(focused, toRight: false)
        case "undo": undo.undo()
        case "save": saveDocument(nil)
        case "hash": computeHash(0); computeHash(1)
        case "openwith": menuNeedsUpdate(openWith.menu!); openWith.performClick(nil)
        case "size": if parts.count == 3, let w = Double(parts[1]), let h = Double(parts[2]) { window?.setContentSize(NSSize(width: w, height: h)) }
        case "dark", "light": window?.appearance = NSAppearance(named: op == "dark" ? .darkAqua : .aqua); refreshLook()
        default: break
        }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else { return false }
        switch event.charactersIgnoringModifiers {
        case "1", "2", "3":
            let m = Int(event.charactersIgnoringModifiers!)! - 1;
            if viewSwitch.isEnabled(forSegment: m) { mode = m; viewSwitch.selectedSegment = m; updateVisibility() }; return true
        case "s": saveDocument(nil); return true
        case "\u{f703}": if event.modifierFlags.contains(.option) { copyChange(focused, toRight: true); return true }; return false
        case "\u{f702}": if event.modifierFlags.contains(.option) { copyChange(focused, toRight: false); return true }; return false
        case "z": if event.modifierFlags.contains(.shift) { undo.redo() } else { undo.undo() }; return true
        case "w": window?.performClose(nil); return true
        case "=", "+": imageCanvas.zoom *= 1.25; return mode == 1
        case "-": imageCanvas.zoom /= 1.25; return mode == 1
        case "0": imageCanvas.zoom = 1; imageCanvas.pan = .zero; return mode == 1
        case "]": move(1); return mode == 0
        case "[": move(-1); return mode == 0
        default: return false
        }
    }
    private func propertyRows() -> [(String, String, String)] {
        guard let a = leftFile, let b = rightFile else { return [] }
        func date(_ value: Date?) -> String { value?.formatted(date: .abbreviated, time: .shortened) ?? "—" }
        func kind(_ url: URL) -> String { UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "Data" }
        var rows = [
            ("Kind", kind(a.url), kind(b.url)), ("Size", "\(a.size.formatted()) bytes", "\(b.size.formatted()) bytes"),
            ("Modified", date(a.modified), date(b.modified)), ("Created", date(a.created), date(b.created)),
            ("Permissions", a.permissions, b.permissions), ("Owner", a.owner, b.owner),
            ("Tags", a.tags.joined(separator: ", "), b.tags.joined(separator: ", ")),
            ("Extended attributes", a.attributes.joined(separator: ", "), b.attributes.joined(separator: ", ")),
        ]
        if let images {
            rows.append(("Dimensions", "\(images.left.width) × \(images.left.height)", "\(images.right.width) × \(images.right.height)"))
        }
        return rows
    }
    private func buildInfo() {
        infoStack.arrangedSubviews.forEach {
            infoStack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        let spacer = NSView(); spacer.heightAnchor.constraint(equalToConstant: 38).isActive = true; infoStack.addArrangedSubview(spacer)
        let headline =
            offset == nil
            ? "\(leftText == nil && images == nil ? "Binary files" : "Files") are identical"
            : (leftText == nil && images == nil ? "Binary files differ" : "Files differ")
        let title = NSTextField(labelWithString: headline); title.font = .systemFont(ofSize: 17, weight: .semibold); title.textColor = Theme.viewText
        addInfoRow(title, height: 28)
        let detail = NSTextField(
            labelWithString: offset.map { "First difference at byte \($0.formatted()) (0x\(String($0, radix: 16)))" } ?? "Every byte matches.")
        detail.font = .systemFont(ofSize: 12); detail.textColor = Theme.viewTextInactive; addInfoRow(detail, height: 36)
        let names = sideNames()
        infoRow("", names.0, names.1, index: -1)
        for (i, row) in propertyRows().enumerated() { infoRow(row.0, row.1.isEmpty ? "—" : row.1, row.2.isEmpty ? "—" : row.2, index: i) }
        let hash = NSStackView(); hash.orientation = .horizontal; hash.spacing = 12
        let label = NSTextField(labelWithString: "SHA-256"); label.font = .systemFont(ofSize: 12); label.textColor = Theme.viewTextInactive;
        label.widthAnchor.constraint(equalToConstant: 126).isActive = true; hash.addArrangedSubview(label)
        for i in 0..<2 {
            if let digest = hashes[i] {
                let text = NSTextField(labelWithString: digest); text.font = .monospacedSystemFont(ofSize: 11, weight: .regular);
                text.lineBreakMode = .byTruncatingMiddle; text.toolTip = digest; text.isSelectable = true; hash.addArrangedSubview(text)
            } else {
                let button = ClosureButton(title: hashBusy.contains(i) ? "Computing…" : "Compute") { [weak self] _ in self?.computeHash(i) };
                button.isEnabled = !hashBusy.contains(i); button.setAccessibilityLabel("Compute SHA-256 for \(i == 0 ? names.0 : names.1)");
                hash.addArrangedSubview(button)
            }
        }
        hash.distribution = .fillEqually; addInfoRow(hash, height: 32); root.needsLayout = true
    }
    private func sideNames() -> (String, String) {
        var a = leftURL.deletingLastPathComponent().lastPathComponent, b = rightURL.deletingLastPathComponent().lastPathComponent
        if a == b {
            a = leftURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent + " › " + a;
            b = rightURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent + " › " + b
        }; return (a, b)
    }
    private func addInfoRow(_ view: NSView, height: CGFloat) {
        view.heightAnchor.constraint(equalToConstant: height).isActive = true; infoStack.addArrangedSubview(view);
        view.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
    }
    private func infoRow(_ property: String, _ left: String, _ right: String, index: Int) {
        let row = FileDiffInfoRow(); row.values = [property, left, right]; row.different = index >= 0 && left != right;
        row.alternate = index % 2 == 0; row.heading = index < 0
        row.setAccessibilityElement(true); row.setAccessibilityRole(.staticText);
        row.setAccessibilityLabel("\(property). \(sideNames().0): \(left). \(sideNames().1): \(right)\(row.different ? ". Different" : "")")
        addInfoRow(row, height: 30)
    }
    private func computeHash(_ side: Int) {
        guard !hashBusy.contains(side) else { return }; hashBusy.insert(side); buildInfo()
        let url = side == 0 ? leftURL : rightURL, token = self.token
        Self.queue.async { [weak self] in
            do {
                let value = try FileChecksums.digest(url, algorithm: .sha256, cancellation: token)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !token.isCancelled else { return }; self.hashes[side] = value; self.hashBusy.remove(side); self.buildInfo()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.hashBusy.remove(side); self?.buildInfo(); self?.showError(error)
                }
            }
        }
    }
}

private enum FileDiffSaveError: LocalizedError {
    case changed(String)
    var errorDescription: String? {
        switch self {
        case .changed(let name): return "“\(name)” changed outside Porpoise. Reopen the comparison before saving."
        }
    }
}

final class FileDiffRoot: NSView {
    weak var owner: FileDiffWindow?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); owner?.layoutContents() }
    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill(); bounds.fill(); Theme.hairline.setFill(); NSRect(x: 0, y: 51, width: bounds.width, height: 1).fill();
        NSRect(x: 0, y: bounds.height - 33, width: bounds.width, height: 1).fill()
    }
}
final class FileDiffNativeWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (windowController as? FileDiffWindow)?.handleKey(event) == true { return true }; return super.performKeyEquivalent(with: event)
    }
}
private final class FileDiffInfoRow: NSView {
    var values: [String] = []; var different = false; var alternate = false; var heading = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (alternate ? Theme.viewAlternate : Theme.viewBackground).setFill(); bounds.fill()
        let label: CGFloat = 138, col = (bounds.width - label) / 2
        for i in values.indices {
            let x: CGFloat = i == 0 ? 12 : label + CGFloat(i - 1) * col
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle
            (values[i] as NSString).draw(
                in: NSRect(x: x, y: 7, width: (i == 0 ? label - 20 : col - 12), height: 18),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: heading || (different && i > 0) ? .semibold : .regular),
                    .foregroundColor: i == 0 ? Theme.viewTextInactive : (different ? Theme.compareChanged : Theme.viewText), .paragraphStyle: p,
                ])
        }
    }
}
