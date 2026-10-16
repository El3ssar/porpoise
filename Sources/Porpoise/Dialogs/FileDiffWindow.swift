import AppKit
import PorpoiseCore
import PorpoiseServices
import UniformTypeIdentifiers

/// Document-like comparison windows, independent of the browser's selection and lifecycle.
final class FileDiffWindow: NSWindowController, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private static var open: [FileDiffWindow] = []
    private static let queue = DispatchQueue(label: "app.porpoise.file-diff", qos: .userInitiated, attributes: .concurrent)
    static var current: FileDiffWindow? { (NSApp.keyWindow?.windowController as? FileDiffWindow) ?? open.last }
    static func present(left: URL, right: URL) {
        if left.isFileURL && right.isFileURL, let path = Settings.store.string(forKey: "fileDiff.defaultApp"),
            FileManager.default.fileExists(atPath: path)
        {
            FileDiffExternalTools.open(URL(fileURLWithPath: path), left: left, right: right) { error in NSAlert(error: error).runModal() }; return
        }
        let controller = FileDiffWindow(left: left, right: right); open.append(controller); controller.showWindow(nil);
        NSApp.activate(ignoringOtherApps: true); controller.window?.makeKeyAndOrderFront(nil)
    }

    let leftURL: URL, rightURL: URL
    private let root = FileDiffRoot()
    private let header = NSView(), footer = NSView(), body = FileDiffBody()
    private let leftCapsule = GlassGroup(), rightCapsule = GlassGroup(), navigation = GlassGroup()
    private let previous = ClosureButton(title: "‹") { _ in }, next = ClosureButton(title: "›") { _ in }
    private let openWith = ClosureButton(title: "Open With ⌄") { _ in }
    private let toolMenu = NSMenu()
    private let externalCapsule = GlassGroup()
    private let viewSwitch = NSSegmentedControl(labels: ["Text", "Image", "Info"], trackingMode: .selectOne, target: nil, action: nil)
    private let textMode = NSSegmentedControl(labels: ["Side by Side", "Inline"], trackingMode: .selectOne, target: nil, action: nil)
    private let imageMode = NSSegmentedControl(
        labels: ["Side by Side", "Onion Skin", "Difference"], trackingMode: .selectOne, target: nil, action: nil)
    private let ignore = ClosureButton(checkboxWithTitle: "Ignore whitespace") { _ in }
    private let blend = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let dimensions = NSTextField(labelWithString: ""), pixelsChanged = NSTextField(labelWithString: "")
    private let blendLeft = NSTextField(labelWithString: ""), blendRight = NSTextField(labelWithString: "")
    private let facts = NSTextField(labelWithString: "Reading files…")
    private let loading = NSProgressIndicator()
    private let progressText = NSTextField(labelWithString: "Reading files…")
    private let cancelComparison = ClosureButton(title: "Cancel") { _ in }
    private let textScroll = NSScrollView(), textCanvas = FileDiffTextView(frame: .zero), imageCanvas = FileDiffImageView()
    private let infoScroll = NSScrollView(), infoStack = NSStackView()
    private let infoDocument = NSView()
    private let message = NSTextField(labelWithString: "")
    private let identicalIcon = FileDiffSuccessIcon(), identicalDetail = NSTextField(labelWithString: "")
    private let undo = UndoManager()
    private var token = DiskCancellation()
    private var generation = 0
    private var leftFile: ComparedFile?, rightFile: ComparedFile?
    private var copies: FileComparisonCopies?
    private var readOnly: Bool { !leftURL.isFileURL || !rightURL.isFileURL }
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
    private var forceOpaque = false
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
        toolMenu.delegate = self; toolMenu.minimumWidth = 190
        openWith.isBordered = false; openWith.font = .systemFont(ofSize: 13)
        openWith.handler = { [weak self] _ in self?.showToolMenu() }
        openWith.setAccessibilityLabel("Open With")
        externalCapsule.content.addSubview(openWith)
        for c in [viewSwitch, textMode, imageMode] {
            c.controlSize = .small; c.target = self; c.action = #selector(controlChanged(_:)); c.selectedSegment = 0
        }
        viewSwitch.setAccessibilityLabel("Comparison View"); textMode.setAccessibilityLabel("Text Layout");
        imageMode.setAccessibilityLabel("Image Comparison Mode")
        for v in [viewSwitch, textMode, imageMode, facts, ignore] { footer.addSubview(v) }
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
        for v in [
            textScroll, imageCanvas, dimensions, pixelsChanged, blend, blendLeft, blendRight, infoScroll, identicalIcon, message, identicalDetail,
            loading, progressText, cancelComparison,
        ] {
            body.addSubview(v)
        }
        for label in [dimensions, pixelsChanged, blendLeft, blendRight] {
            label.font = .systemFont(ofSize: 12); label.textColor = Theme.viewTextInactive
        }
        pixelsChanged.font = .systemFont(ofSize: 12, weight: .semibold); pixelsChanged.textColor = Theme.compareChanged;
        pixelsChanged.alignment = .right
        blendLeft.alignment = .right; blendRight.alignment = .left
        imageCanvas.onOpacityChange = { [weak self] value in self?.blend.doubleValue = Double(value) }
        identicalDetail.font = .systemFont(ofSize: 12); identicalDetail.textColor = Theme.viewTextInactive; identicalDetail.alignment = .center
        message.font = .systemFont(ofSize: 15, weight: .semibold); message.textColor = Theme.viewText; message.alignment = .center;
        message.maximumNumberOfLines = 2
        loading.style = .bar; loading.controlSize = .small; loading.isIndeterminate = true; loading.startAnimation(nil)
        progressText.font = .systemFont(ofSize: 12); progressText.textColor = Theme.viewTextInactive; progressText.alignment = .center
        cancelComparison.bezelStyle = .rounded; cancelComparison.keyEquivalent = "\u{1b}"; cancelComparison.keyEquivalentModifierMask = []
        cancelComparison.handler = { [weak self] _ in self?.window?.performClose(nil) }
        previous.nextKeyView = next; next.nextKeyView = openWith
        openWith.nextKeyView = viewSwitch; viewSwitch.nextKeyView = textMode; textMode.nextKeyView = ignore
        updateVisibility()
    }
    private func addFile(_ url: URL, to capsule: GlassGroup) {
        let icon = NSImageView();
        icon.image = Icons.shared.image(
            for: FileItem(
                url: url, name: url.lastPathComponent, isDirectory: false, contentType: UTType(filenameExtension: url.pathExtension)?.identifier),
            size: 18);
        icon.frame = NSRect(x: 12, y: 8, width: 18, height: 18)
        let name = NSTextField(labelWithString: url.lastPathComponent); name.font = .systemFont(ofSize: 13, weight: .semibold);
        name.textColor = Theme.windowText; name.lineBreakMode = .byTruncatingMiddle
        let path = NSTextField(labelWithString: url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: " › "));
        path.font = .systemFont(ofSize: 12); path.textColor = Theme.windowTextInactive; path.lineBreakMode = .byTruncatingMiddle
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
                let url = capsule === leftCapsule ? leftURL : rightURL
                let parts = capsulePath(for: url)
                let fullPath = parts.joined(separator: " › ")
                let pathWidth = max(0, cap - 56 - nameW)
                let fullWidth = (fullPath as NSString).size(withAttributes: [.font: labels[1].font!]).width
                var shown = fullPath
                if fullWidth > pathWidth {
                    shown = parts.count > 2 ? "\(parts.first!) › … › \(parts.last!)" : fullPath
                    if (shown as NSString).size(withAttributes: [.font: labels[1].font!]).width > pathWidth {
                        shown = "\(parts.first ?? "") › …"
                    }
                }
                labels[1].stringValue = shown; labels[1].lineBreakMode = .byClipping
                labels[1].frame = NSRect(x: 44 + nameW, y: 10, width: max(0, cap - 56 - nameW), height: 16)
            }
        }
        viewSwitch.frame = NSRect(x: 12, y: 5, width: 144, height: 23)
        let controlWidth: CGFloat = mode == 1 ? (w < 850 ? 242 : 280) : 154
        textMode.frame = NSRect(x: 166, y: 5, width: controlWidth, height: 23); imageMode.frame = textMode.frame
        ignore.frame = NSRect(x: w - 143, y: 7, width: 135, height: 20)
        let x: CGFloat = mode == 2 ? 170 : 174 + controlWidth
        facts.frame = NSRect(x: x, y: 9, width: max(0, w - x - (mode == 0 ? 151 : 14)), height: 16)
        let imageBottom: CGFloat = imageMode.selectedSegment == 1 ? 82 : 24
        imageCanvas.frame = NSRect(x: 24, y: 54, width: w - 48, height: max(40, body.bounds.height - 54 - imageBottom))
        dimensions.frame = NSRect(x: 24, y: 22, width: w * 0.6 - 24, height: 22)
        pixelsChanged.frame = NSRect(x: w * 0.6, y: 23, width: w * 0.4 - 24, height: 20)
        if let images {
            let maxW = CGFloat(max(images.left.width, images.right.width)), maxH = CGFloat(max(images.left.height, images.right.height))
            let availableWidth = imageMode.selectedSegment == 0 ? imageCanvas.bounds.width / 2 - 12 : imageCanvas.bounds.width
            let scale = min(availableWidth / maxW, imageCanvas.bounds.height / maxH) * imageCanvas.zoom
            let inset = max(0, (availableWidth - maxW * scale) / 2)
            let left = imageCanvas.frame.minX + inset, right = imageCanvas.frame.maxX - inset
            dimensions.frame = NSRect(x: left, y: 22, width: (right - left) * 0.62, height: 22)
            pixelsChanged.frame = NSRect(x: left + (right - left) * 0.62, y: 23, width: (right - left) * 0.38, height: 20)
        }
        let blendWidth: CGFloat = min(320, w - 300)
        blend.frame = NSRect(x: (w - blendWidth) / 2, y: body.bounds.height - 52, width: blendWidth, height: 24)
        blendLeft.frame = NSRect(x: blend.frame.minX - 140, y: blend.frame.minY + 4, width: 128, height: 18)
        blendRight.frame = NSRect(x: blend.frame.maxX + 12, y: blend.frame.minY + 4, width: 128, height: 18)
        for v in [textScroll, infoScroll] { v.frame = body.bounds }
        resizeText()
        let infoWidth = min(780, max(550, w - 80));
        infoDocument.frame = NSRect(x: 0, y: 0, width: w, height: max(body.bounds.height, infoStack.fittingSize.height + 56));
        infoStack.frame = NSRect(x: (w - infoWidth) / 2, y: 0, width: infoWidth, height: max(body.bounds.height, infoStack.fittingSize.height + 56))
        for row in infoStack.arrangedSubviews { row.setFrameSize(NSSize(width: infoWidth, height: row.frame.height)) }
        let identicalTop = (body.bounds.height - 110) / 2
        identicalIcon.frame = NSRect(x: w / 2 - 24, y: identicalTop, width: 48, height: 48)
        message.frame = NSRect(x: 30, y: identicalTop + 64, width: w - 60, height: 22)
        identicalDetail.frame = NSRect(x: 30, y: identicalTop + 92, width: w - 60, height: 18)
        loading.frame = NSRect(x: w / 2 - 140, y: body.bounds.height / 2 - 30, width: 280, height: 6)
        progressText.frame = NSRect(x: 30, y: body.bounds.height / 2 - 8, width: w - 60, height: 20)
        cancelComparison.frame = NSRect(x: w / 2 - 42, y: body.bounds.height / 2 + 24, width: 84, height: 24)
    }
    private func resizeText() {
        textCanvas.frame = NSRect(
            x: 0, y: 0, width: textScroll.contentSize.width,
            height: max(textScroll.contentSize.height, CGFloat(textCanvas.presentation?.rows.count ?? 0) * 18 + 24));
        textCanvas.needsDisplay = true; textCanvas.updateCopyButtons()
    }
    private func refreshLook() {
        for capsule in [leftCapsule, rightCapsule, navigation, externalCapsule] {
            capsule.content.wantsLayer = true; capsule.content.layer?.cornerRadius = 17
            capsule.content.layer?.backgroundColor =
                (forceOpaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) ? Theme.windowBackground.cgColor : nil
        }
        window?.backgroundColor = Theme.windowBackground; root.needsDisplay = true; textCanvas.needsDisplay = true; imageCanvas.needsDisplay = true;
        if ready { buildInfo() }
    }
    private func read() {
        let token = self.token, left = leftURL, right = rightURL
        let isImage = [left, right].allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        Self.queue.async { [weak self] in
            do {
                let copies = try FileComparisonCopies(left: left, right: right, cancellation: token)
                let localLeft = copies.left, localRight = copies.right
                let binaryExtensions: Set<String> = [
                    "numbers", "pages", "key", "pdf", "zip", "gz", "dmg", "mp4", "mov", "mp3", "sqlite", "db", "exe",
                ]
                let throttle = NSLock(); var lastProgress = Date.distantPast
                func progress(_ name: String, _ bytes: UInt64, _ total: UInt64) {
                    // Visual-review hook only; the responsiveness probe runs without this variable.
                    if Settings.isTesting, let value = ProcessInfo.processInfo.environment["PORPOISE_FILEDIFF_READ_DELAY_MS"],
                        let milliseconds = Double(value), milliseconds > 0
                    {
                        Thread.sleep(forTimeInterval: min(milliseconds, 100) / 1000)
                    }
                    guard
                        throttle.withLock({
                            if Date().timeIntervalSince(lastProgress) < 0.08 && bytes < total { return false }; lastProgress = Date(); return true
                        })
                    else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !token.isCancelled, self.busy else { return }
                        self.loading.stopAnimation(nil); self.loading.isIndeterminate = false
                        self.loading.minValue = 0; self.loading.maxValue = 100
                        self.loading.doubleValue = Double(bytes) / Double(max(1, total)) * 100
                        self.loading.needsDisplay = true
                        self.progressText.stringValue = "Reading \(name)… \(FileFormat.size(Int64(bytes))) of \(FileFormat.size(Int64(total)))"
                        self.facts.stringValue = self.progressText.stringValue
                    }
                }
                let
                    a = try ComparedFile(
                        url: localLeft, readText: !isImage && !binaryExtensions.contains(left.pathExtension.lowercased()), cancellation: token,
                        progress: { progress(left.lastPathComponent, $0, $1) }),
                    b = try ComparedFile(
                        url: localRight, readText: !isImage && !binaryExtensions.contains(right.pathExtension.lowercased()), cancellation: token,
                        progress: { progress(right.lastPathComponent, $0, $1) })
                let offset = try FileComparison.firstDifference(localLeft, localRight, cancellation: token)
                let images = isImage ? try FileDiffImages.load(localLeft, localRight) : nil
                try token.check()
                DispatchQueue.main.async {
                    guard let self, !token.isCancelled else { return }
                    self.copies = copies; self.textCanvas.canCopyChanges = !self.readOnly
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
        loading.stopAnimation(nil); loading.isHidden = true; progressText.isHidden = true; cancelComparison.isHidden = true
    }
    private func rediff() {
        guard ready else { return }
        generation += 1; let version = generation
        guard let a = leftText, let b = rightText else { busy = false; updateVisibility(); return }
        busy = true; facts.stringValue = "Comparing…"; progressText.stringValue = "Comparing…";
        loading.isIndeterminate = true; loading.startAnimation(nil); updateVisibility()
        let whitespace = ignore.state == .on, inline = textMode.selectedSegment == 1
        Self.queue.async { [weak self] in
            let difference = TextDifference(left: a, right: b, ignoreWhitespace: whitespace)
            let presentation = FileDiffPresentation(difference, inline: inline)
            DispatchQueue.main.async {
                guard let self, self.generation == version, !self.token.isCancelled else { return }
                self.textCanvas.presentation = presentation; self.textCanvas.inline = inline; self.busy = false
                self.focused = min(self.focused, max(0, presentation.starts.count - 1)); self.textCanvas.focused = self.focused;
                self.textCanvas.updateCopyButtons()
                self.resizeText(); self.updateVisibility(); self.root.layoutSubtreeIfNeeded()
                if !presentation.starts.isEmpty { self.focus(self.focused) }
            }
        }
    }
    private func updateVisibility() {
        textScroll.isHidden = mode != 0 || busy; imageCanvas.isHidden = mode != 1 || busy; infoScroll.isHidden = mode != 2 || busy
        textMode.isHidden = mode != 0; imageMode.isHidden = mode != 1; blend.isHidden = mode != 1 || imageMode.selectedSegment != 1;
        ignore.isHidden = mode != 0
        dimensions.isHidden = mode != 1; pixelsChanged.isHidden = mode != 1
        blendLeft.isHidden = blend.isHidden; blendRight.isHidden = blend.isHidden
        let count = textCanvas.presentation?.difference.changes.count ?? 0
        openWith.isEnabled = ready && !busy
        previous.isEnabled = mode == 0 && count > 0 && !busy; next.isEnabled = previous.isEnabled
        loading.isHidden = !busy; progressText.isHidden = !busy; cancelComparison.isHidden = !busy; if !busy { loading.stopAnimation(nil) }
        let identical = mode == 0 && !busy && ready && textCanvas.presentation != nil && count == 0
        message.isHidden = !identical; identicalIcon.isHidden = !identical; identicalDetail.isHidden = !identical
        message.stringValue = "The files are identical"
        identicalDetail.stringValue = "Same contents · \((leftFile?.size ?? 0).formatted(.number.locale(Locale(identifier: "en_US")))) bytes"
        if identical, let a = leftFile, let b = rightFile, a.modified != b.modified {
            identicalDetail.stringValue = "Metadata differs: modified date"
        }
        textMode.isEnabled = !identical
        textScroll.isHidden = mode != 0 || identical || busy
        if !busy {
            if mode == 0 {
                facts.stringValue =
                    "\(count == 1 ? "1 change" : (count > 1 ? "\(focused + 1) of \(count) changes" : "No changes")) · UTF-8 · \(lineEnding)"
            } else if mode == 1, let images {
                let sameSize = images.left.width == images.right.width && images.left.height == images.right.height
                dimensions.stringValue =
                    sameSize
                    ? "\(images.left.width) × \(images.left.height) · both"
                    : "\(images.left.width) × \(images.left.height) vs \(images.right.width) × \(images.right.height)"
                dimensions.isBezeled = !sameSize; dimensions.bezelStyle = .roundedBezel
                pixelsChanged.stringValue = String(format: "%.1f %% pixels differ%@", images.changedPercent ?? 0, images.sampled ? " (sampled)" : "")
                let names = sideNames(); blendLeft.stringValue = names.0; blendRight.stringValue = names.1
                facts.stringValue = "\(FileFormat.size(Int64(leftFile?.size ?? 0))) · \(FileFormat.size(Int64(rightFile?.size ?? 0)))"

            } else {
                facts.stringValue = "\(propertyRows().filter { $0.1 != $0.2 }.count) properties differ"
            }
        }
        if busy { facts.stringValue = "Comparing…" }
        if readOnly { facts.stringValue += " · Read-only downloaded copy" }
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
        let viewport = textScroll.contentView
        let y = max(0, min(CGFloat(p.starts[change]) * 18 + 10 - viewport.bounds.height / 3, textCanvas.bounds.height - viewport.bounds.height))
        viewport.scroll(to: NSPoint(x: 0, y: y)); textScroll.reflectScrolledClipView(viewport)
        textCanvas.needsDisplay = true
        let c = p.difference.changes[change]
        let speech =
            "Change \(change + 1) of \(p.starts.count). Left line \(c.left.lowerBound + 1), \(c.left.count) lines. Right line \(c.right.lowerBound + 1), \(c.right.count) lines."
        let leftExcerpt = p.difference.left[c.left].prefix(3).map { String($0.prefix(500)) }.joined(),
            rightExcerpt = p.difference.right[c.right].prefix(3).map { String($0.prefix(500)) }.joined()
        textCanvas.setAccessibilityValue(speech + " Left: " + leftExcerpt + " Right: " + rightExcerpt)
        NSAccessibility.post(element: textCanvas, notification: .valueChanged)
        updateVisibility()
    }
    func copyChange(_ index: Int, toRight: Bool) {
        guard !busy, !readOnly, let d = textCanvas.presentation?.difference else { return }
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
        guard !busy, !readOnly else { failed?(); return }
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
        menu.appearance = window?.effectiveAppearance
        menu.removeAllItems()
        for tool in FileDiffExternalTools.installed {
            let item = NSMenuItem(title: tool.name, action: #selector(openExternal(_:)), keyEquivalent: ""); item.target = self;
            item.representedObject = tool.url; menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: "No compare apps found", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
        }
        menu.addItem(.separator()); let choose = NSMenuItem(title: "Choose Default App…", action: #selector(chooseExternal), keyEquivalent: "");
        choose.target = self; menu.addItem(choose)
    }
    @objc private func openExternal(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        copies?.keepForExternalApplication()
        FileDiffExternalTools.open(app, left: copies?.left ?? leftURL, right: copies?.right ?? rightURL) { [weak self] error in self?.showError(error)
        }
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
        case "contrast": textCanvas.forceContrast = true; textCanvas.needsDisplay = true
        case "opaque": forceOpaque = true; refreshLook()
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
        case "openwith": openWith.performClick(nil)
        case "size":
            if parts.count == 3, let w = Double(parts[1]), let h = Double(parts[2]) {
                window?.setContentSize(NSSize(width: w, height: h)); window?.center()
            }
        case "dark", "light": window?.appearance = NSAppearance(named: op == "dark" ? .darkAqua : .aqua); refreshLook()
        default: break
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)): return !readOnly && dirty && !busy
        case #selector(undoFileOperation(_:)): return undo.canUndo
        case #selector(redoFileOperation(_:)): return undo.canRedo
        default: return true
        }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 && busy { window?.performClose(nil); return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else { return false }
        if event.modifierFlags.contains(.control) {
            if event.keyCode == 125 { move(1); return true }
            if event.keyCode == 126 { move(-1); return true }
        }
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
            ("Kind", kind(a.url), kind(b.url)),
            (
                "Size", "\(a.size.formatted(.number.locale(Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")))) bytes",
                "\(b.size.formatted(.number.locale(Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")))) bytes"
            ),
            ("Modified", date(a.modified), date(b.modified)), ("Created", date(a.created), date(b.created)),
            (
                "Permissions", FileFormat.permissions(Int(a.permissions, radix: 8) ?? 0, isDirectory: false),
                FileFormat.permissions(Int(b.permissions, radix: 8) ?? 0, isDirectory: false)
            ), ("Owner", a.owner, b.owner),
            ("Tags", a.tags.joined(separator: ", "), b.tags.joined(separator: ", ")),
            (
                "Extended attributes", a.attributes.map { $0.components(separatedBy: " · ")[0] }.joined(separator: ", "),
                b.attributes.map { $0.components(separatedBy: " · ")[0] }.joined(separator: ", ")
            ),
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
        let detail = NSTextField(
            labelWithString: offset.map {
                "First difference at byte \($0.formatted(.number.locale(Locale(identifier: "en_US")))) (0x\(String($0, radix: 16)))"
            } ?? "Every byte matches.")
        detail.font = .systemFont(ofSize: 12); detail.textColor = Theme.viewTextInactive
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 2
        let icon = NSImageView();
        icon.image = Icons.shared.image(
            for: FileItem(
                url: leftURL, name: leftURL.lastPathComponent, isDirectory: false,
                contentType: UTType(filenameExtension: leftURL.pathExtension)?.identifier), size: 40)
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true; icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let heading = NSStackView(views: [icon, labels]); heading.spacing = 14; heading.alignment = .centerY
        addInfoRow(heading, height: 70)
        let table = NSStackView(); table.orientation = .vertical; table.alignment = .leading; table.spacing = 0
        table.wantsLayer = true; table.layer?.cornerRadius = 5; table.layer?.masksToBounds = true; table.layer?.borderWidth = 1;
        window?.effectiveAppearance.performAsCurrentDrawingAppearance { table.layer?.borderColor = Theme.frame.cgColor }
        let names = sideNames()
        infoRow("", names.0, names.1, index: -1, table: table)
        let rows = propertyRows()
        for (i, row) in rows.enumerated() { infoRow(row.0, row.1.isEmpty ? "—" : row.1, row.2.isEmpty ? "—" : row.2, index: i, table: table) }
        let hash = FileDiffHashRow()
        for i in 0..<2 {
            if let digest = hashes[i] {
                let text = NSTextField(labelWithString: digest); text.font = .monospacedSystemFont(ofSize: 11, weight: .regular);
                text.textColor = Theme.viewText
                text.lineBreakMode = .byTruncatingMiddle; text.toolTip = digest; text.isSelectable = true; hash.cells.append(text)
            } else {
                let button = ClosureButton(title: hashBusy.contains(i) ? "Computing…" : "Compute") { [weak self] _ in self?.computeHash(i) }
                button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 12)
                button.isEnabled = !hashBusy.contains(i); button.setAccessibilityLabel("Compute SHA-256 for \(i == 0 ? names.0 : names.1)");
                hash.cells.append(button)
            }
        }
        hash.cells.forEach(hash.addSubview); table.addArrangedSubview(hash)
        hash.heightAnchor.constraint(equalToConstant: 32).isActive = true; hash.widthAnchor.constraint(equalTo: table.widthAnchor).isActive = true
        addInfoRow(table, height: CGFloat(rows.count + 1) * 30 + 32); root.needsLayout = true
    }
    private func sideNames() -> (String, String) {
        let left = leftURL.deletingLastPathComponent().pathComponents, right = rightURL.deletingLastPathComponent().pathComponents
        if left == right && (leftURL.host != rightURL.host) {
            return (
                leftURL.host ?? leftURL.deletingLastPathComponent().lastPathComponent,
                rightURL.host ?? rightURL.deletingLastPathComponent().lastPathComponent
            )
        }
        var count = 1
        while count < max(left.count, right.count) && left.suffix(count) == right.suffix(count) { count += 1 }
        return (left.suffix(count).first ?? leftURL.lastPathComponent, right.suffix(count).first ?? rightURL.lastPathComponent)
    }
    private func capsulePath(for url: URL) -> [String] {
        let own = url.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        if !url.isFileURL { return [url.host ?? "Remote"] + own.suffix(2) }
        let otherURL = url == leftURL ? rightURL : leftURL
        guard otherURL.isFileURL else { return Array(own.suffix(3)) }
        let other = otherURL.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        var common = 0
        while common < min(own.count, other.count) && own[common] == other[common] { common += 1 }
        let relative = Array(own.dropFirst(common))
        if relative.isEmpty { return Array(own.suffix(2)) }
        return relative.count > 3 ? [relative.first!, "…", relative.last!] : relative
    }
    private func showToolMenu() {
        menuNeedsUpdate(toolMenu)
        toolMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: openWith)
    }
    func endToolMenu() { toolMenu.cancelTracking() }

    private func addInfoRow(_ view: NSView, height: CGFloat) {
        view.heightAnchor.constraint(equalToConstant: height).isActive = true; infoStack.addArrangedSubview(view);
        view.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
    }
    private func infoRow(_ property: String, _ left: String, _ right: String, index: Int, table: NSStackView) {
        let row = FileDiffInfoRow(); row.values = [property, left, right]; row.different = index >= 0 && left != right;
        if property == "Extended attributes", let a = leftFile, let b = rightFile {
            row.different = a.attributes != b.attributes; row.toolTip = (a.attributes + b.attributes).joined(separator: "\n")
        }
        if property == "Permissions" { row.toolTip = "\(leftFile?.permissions ?? "") · \(rightFile?.permissions ?? "")" }
        row.alternate = index % 2 == 0; row.heading = index < 0
        row.setAccessibilityElement(true); row.setAccessibilityRole(.staticText);
        row.setAccessibilityLabel("\(property). \(sideNames().0): \(left). \(sideNames().1): \(right)\(row.different ? ". Different" : "")")
        table.addArrangedSubview(row); row.heightAnchor.constraint(equalToConstant: 30).isActive = true;
        row.widthAnchor.constraint(equalTo: table.widthAnchor).isActive = true
    }
    private func computeHash(_ side: Int) {
        guard !hashBusy.contains(side) else { return }; hashBusy.insert(side); buildInfo()
        let url = side == 0 ? (copies?.left ?? leftURL) : (copies?.right ?? rightURL), token = self.token
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

private final class FileDiffBody: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Theme.viewBackground.setFill(); bounds.fill() }
}
private final class FileDiffHashRow: NSView {
    var cells: [NSView] = []
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout(); let col = (bounds.width - 138) / 2
        for (i, cell) in cells.enumerated() {
            let button = cell is NSButton
            cell.frame = NSRect(x: 138 + CGFloat(i) * col, y: button ? 5 : 8, width: button ? 96 : col - 12, height: button ? 22 : 18)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.viewAlternate.setFill(); bounds.fill()
        ("SHA-256" as NSString).draw(
            at: NSPoint(x: 12, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.viewTextInactive])
    }
}

private final class FileDiffSuccessIcon: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.compareOnly.withAlphaComponent(effectiveAppearance.isDark ? 0.20 : 0.16).setFill(); NSBezierPath(ovalIn: bounds).fill()
        ("✓" as NSString).draw(
            at: NSPoint(x: 14, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 25, weight: .medium), .foregroundColor: Theme.compareOnly])
    }
}
