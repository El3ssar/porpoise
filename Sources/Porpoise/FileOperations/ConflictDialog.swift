import AppKit
import PorpoiseCore
import PorpoiseServices
import QuickLookThumbnailing

/// A window-owned question. No nested modal run loop is used by running transfers.
final class ConflictDialog: NSObject {
    let info: ConflictInfo
    let kind: FileOperationKind
    let window: NSWindow
    private let applyAll = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let method = NSPopUpButton()
    private let counts = NSTextField(labelWithString: "")
    private var completion: ((ConflictAnswer) -> Void)?
    private var retainedSelf: ConflictDialog?
    private let methods: [SyncCompareMethod] = [.sizeAndDate, .sizeOnly, .content]

    init(info: ConflictInfo, kind: FileOperationKind) {
        self.info = info
        self.kind = kind
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 374), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.contentView = ConflictBackdropView(frame: CGRect(x: 0, y: 0, width: 620, height: 374))
        build()
    }

    private func label(_ text: String, _ rect: CGRect, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? Theme.windowTextInactive : Theme.windowText
        field.frame = rect
        window.contentView!.addSubview(field)
        return field
    }

    private func build() {
        let bothFolders = info.source.isBrowsableFolder && info.destination.isBrowsableFolder
        let delta = (info.source.modificationDate?.timeIntervalSince1970 ?? 0) - (info.destination.modificationDate?.timeIntervalSince1970 ?? 0)
        let newer = delta > info.comparisonOptions.timestampTolerance
        let older = delta < -info.comparisonOptions.timestampTolerance
        window.title = "Names Clash"
        window.backgroundColor = Theme.windowBackground
        let sizeDelta = info.source.size - info.destination.size
        let sizeHint = !bothFolders && sizeDelta != 0 ? " and \(FileFormat.size(abs(sizeDelta))) \(sizeDelta > 0 ? "larger" : "smaller")" : ""
        let hint: String
        if bothFolders {
            hint = "Merge adds items to the existing folder. Names that clash inside will ask again."
        } else if info.source.isDirectory != info.destination.isDirectory {
            hint = "A \(info.source.isDirectory ? "folder" : "file") will replace the existing \(info.destination.isDirectory ? "folder" : "file")."
        } else if newer {
            hint = "The item you’re \(kind == .move ? "moving" : "copying") is newer" + sizeHint + "."
        } else if older {
            hint = "The incoming item is older" + sizeHint + ". Skip keeps the newer version."
        } else if info.source.size == info.destination.size {
            hint = "They look identical: same size and date. Compare contents to check every byte."
        } else {
            hint = "The items have different sizes."
        }
        let hintHeight = ceil(
            (hint as NSString).boundingRect(
                with: CGSize(width: 580, height: 40), options: .usesLineFragmentOrigin, attributes: [.font: NSFont.systemFont(ofSize: 12)]
            ).height)
        let height = max(16, hintHeight)
        window.setContentSize(CGSize(width: 620, height: 358 + height))
        _ = label(
            (bothFolders ? "A folder named “\(info.source.name)”" : "“\(info.source.name)”")
                + " already exists in \(info.destination.url.deletingLastPathComponent().lastPathComponent)",
            CGRect(x: 20, y: 324 + height, width: 450, height: 18), size: 13, weight: .semibold)
        _ = label(hint, CGRect(x: 20, y: 321, width: 580, height: height), secondary: true)
        card(
            info.destination, heading: "In \(info.destination.url.deletingLastPathComponent().lastPathComponent)", x: 20, newer: older,
            larger: bothFolders
                ? ((info.destinationFolder?.bytes ?? 0) > (info.sourceFolder?.bytes ?? .max)) : info.destination.size > info.source.size,
            summary: info.destinationFolder)
        card(
            info.source, heading: kind.verb, x: 326, newer: newer,
            larger: bothFolders
                ? ((info.sourceFolder?.bytes ?? 0) > (info.destinationFolder?.bytes ?? .max)) : info.source.size > info.destination.size,
            summary: info.sourceFolder)
        _ = label("→", CGRect(x: 300, y: 229, width: 22, height: 24), size: 17, secondary: true)

        let strip = NSView(frame: CGRect(x: 20, y: 95, width: 580, height: 66))
        strip.wantsLayer = true
        strip.layer?.cornerRadius = 8
        strip.layer?.borderWidth = 1
        Theme.whenChanged(strip) { [weak strip] in
            strip?.layer?.backgroundColor = Theme.activeText.withAlphaComponent(0.08).cgColor
            strip?.layer?.borderColor = Theme.activeText.withAlphaComponent(0.25).cgColor
        }
        window.contentView!.addSubview(strip)
        _ = label("⇄  Replace if different, skip if identical", CGRect(x: 32, y: 133, width: 388, height: 18), size: 12, weight: .semibold)
        method.addItems(withTitles: ["By size & date · 2 s tolerance", "By size only", "By contents"])
        method.selectItem(at: methods.firstIndex(of: info.comparisonOptions.method) ?? 0)
        method.font = .systemFont(ofSize: 11)
        method.controlSize = .small
        method.frame = CGRect(x: 238, y: 103, width: 234, height: 24)
        method.removeAllItems(); method.addItems(withTitles: ["Size & date · 2 s", "Size only", "Contents"])
        method.selectItem(at: methods.firstIndex(of: info.comparisonOptions.method) ?? 0)
        method.target = self; method.action = #selector(methodChanged)
        counts.frame = CGRect(x: 32, y: 107, width: 202, height: 16)
        counts.font = .systemFont(ofSize: 11); counts.textColor = Theme.windowTextInactive
        window.contentView!.addSubview(counts)
        methodChanged()
        method.toolTip = "The same comparison method used by folder sync. Size & date compares metadata; Contents reads every byte."
        window.contentView!.addSubview(method)
        let total = info.remainingConflicts ?? 1
        let rule = ConflictActionButton(title: total > 1 ? "Apply to All \(total)" : "Apply", target: self, action: #selector(different))
        rule.font = .systemFont(ofSize: 11)
        rule.bezelStyle = .rounded
        rule.titleTint = Theme.activeText
        rule.frame = CGRect(x: 482, y: 115, width: 108, height: 28)
        window.contentView!.addSubview(rule)
        applyAll.title = total > 1 ? "Do this for the other \(total - 1) conflicts" : "Do this for later conflicts in this transfer"
        if total > 1 { _ = label("Conflict 1 of \(total)", CGRect(x: 470, y: 325 + height, width: 130, height: 18), size: 11, secondary: true) }
        applyAll.font = .systemFont(ofSize: 11)
        applyAll.frame = CGRect(x: 20, y: 63, width: 386, height: 22)
        window.contentView!.addSubview(applyAll)
        func button(_ title: String, x: CGFloat, width: CGFloat, action: Selector, key: String = "") -> NSButton {
            let button = ConflictActionButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.frame = CGRect(x: x, y: 19, width: width, height: 30)
            button.keyEquivalent = key
            button.primary = key == "\r"
            window.contentView!.addSubview(button)
            return button
        }
        _ = button(kind == .move ? "Stop Moving" : "Stop Copying", x: 16, width: 114, action: #selector(cancel), key: "\u{1b}")
        _ = button("Skip", x: 274, width: 64, action: #selector(skip), key: !newer && !bothFolders ? "\r" : "")
        let keep = button("Keep Both", x: 344, width: 94, action: #selector(keepBoth), key: "d")
        keep.keyEquivalentModifierMask = .command
        keep.toolTip = "Save as “\(info.suggestedName)”"
        let title =
            bothFolders
            ? "Merge"
            : older
                ? "Replace with Older"
                : info.destination.isDirectory != info.source.isDirectory
                    ? (info.destination.isDirectory ? "Replace Folder" : "Replace File") : "Replace"
        let split = ConflictSplitView(frame: CGRect(x: 446, y: 19, width: 154, height: 30))
        split.primary = newer || bothFolders
        split.showsDivider = !bothFolders
        window.contentView!.addSubview(split)
        let replace = ConflictActionButton(title: title, target: self, action: #selector(replace))
        replace.drawsBackground = false; replace.primary = split.primary
        replace.font = .systemFont(ofSize: 12)
        replace.keyEquivalent = split.primary ? "\r" : ""
        replace.frame = CGRect(x: 0, y: 0, width: bothFolders ? 154 : 128, height: 30)
        split.addSubview(replace)
        let arrow = ConflictActionButton(title: "⌄", target: self, action: #selector(choices))
        arrow.drawsBackground = false; arrow.primary = split.primary
        arrow.frame = CGRect(x: 129, y: 0, width: 25, height: 30)
        arrow.toolTip = "Conditional replacement rules"
        arrow.isHidden = bothFolders
        split.addSubview(arrow)
    }

    private func card(_ item: FileItem, heading: String, x: CGFloat, newer: Bool, larger: Bool, summary: TransferFolderSummary? = nil) {
        let box = NSView(frame: CGRect(x: x, y: 173, width: 274, height: 136))
        box.wantsLayer = true; box.layer?.cornerRadius = 8; box.layer?.borderWidth = 1
        Theme.whenChanged(box) { [weak box] in
            box?.layer?.backgroundColor = Theme.viewBackground.cgColor
            box?.layer?.borderColor = Theme.frame.cgColor
        }
        window.contentView!.addSubview(box)
        _ = label(heading, CGRect(x: x + 12, y: 285, width: 250, height: 16), size: 11, weight: .semibold, secondary: true)
        let image = NSImageView(frame: CGRect(x: x + 12, y: 207, width: 64, height: 64))
        image.image = Icons.shared.image(for: item, size: 64)
        if item.url.isFileURL {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 64, height: 64), scale: 2, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak image] thumbnail, _ in
                guard let thumbnail, thumbnail.type != .icon else { return }
                DispatchQueue.main.async {
                    image?.image = thumbnail.nsImage; image?.contentTintColor = nil
                }
            }
        }
        image.toolTip = item.url.absoluteString
        window.contentView!.addSubview(image)
        let name = label(item.name, CGRect(x: x + 86, y: 253, width: 176, height: 19), size: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let sizeText: String
        if item.isBrowsableFolder {
            sizeText =
                summary.map { FileFormat.itemCount($0.itemCount) + ($0.bytes.map { ", " + FileFormat.size($0) } ?? "") } ?? "Contents not counted"
        } else {
            sizeText = FileFormat.size(item.size)
        }
        let size = label(sizeText, CGRect(x: x + 86, y: 235, width: 176, height: 18))
        if larger { size.textColor = Theme.compareChanged }
        let formatter = DateFormatter()
        formatter.locale = .current; formatter.dateFormat = "d MMM yyyy, HH:mm"
        let dateText = item.modificationDate.map { formatter.string(from: $0) } ?? "Date unavailable"
        let date = label(dateText, CGRect(x: x + 86, y: 217, width: newer ? 124 : 176, height: 16), size: 10.5, secondary: !newer)
        date.lineBreakMode = .byTruncatingTail; date.toolTip = dateText
        if newer { date.textColor = Theme.compareChanged }
        for (text, value, y, fontSize, shown) in [("Newer", dateText, 217.0, 10.5, newer), ("Larger", sizeText, 235.0, 12.0, larger)] where shown {
            let width = (value as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
            let badge = ConflictBadge(text: text)
            badge.frame = CGRect(x: x + 86 + min(124, ceil(width)) + 6, y: y, width: 46, height: 16)
            window.contentView!.addSubview(badge)
        }
        let badges = [newer ? "Newer" : nil, larger ? "Larger" : nil].compactMap { $0 }.joined(separator: " · ")
        _ = label(
            item.isDirectory
                ? "Folder" : (item.contentType == nil && item.url.pathExtension.lowercased() == "pdf" ? "PDF document" : item.typeDescription),
            CGRect(x: x + 86, y: 199, width: 176, height: 16), size: 11, secondary: true)
        box.setAccessibilityElement(true)
        box.setAccessibilityLabel("\(heading): \(item.name), \(FileFormat.size(item.size)), \(badges)")
    }

    @objc private func methodChanged() {
        if methods[method.indexOfSelectedItem] == info.comparisonOptions.method, let different = info.differentItems,
            let identical = info.identicalItems
        {
            counts.stringValue = "\(different) different · \(identical) identical so far"
        } else {
            counts.stringValue = "\(info.replacedItems) replaced · \(info.skippedIdenticalItems) identical so far"
        }
        counts.toolTip = "File comparisons by the selected method; folders are compared through their contents. Counts exclude folders."
    }

    @objc private func choices(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [
            ("Replace if Newer", #selector(newer)), ("Replace if Larger", #selector(larger)), ("Replace if Different", #selector(differentOnce)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    private func finish(_ resolution: ConflictResolution, all: Bool = false) {
        guard let completion else { return }
        self.completion = nil
        let answer = ConflictAnswer(resolution, applyToAll: all || applyAll.state == .on, comparisonMethod: methods[method.indexOfSelectedItem])
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
        completion(answer)
        retainedSelf = nil
    }
    @objc func cancel() { finish(.cancel) }
    @objc private func skip() { finish(.skip) }
    @objc private func keepBoth() { finish(.keepBoth) }
    @objc private func newer() { finish(.overwriteIfOlder) }
    @objc private func larger() { finish(.overwriteIfLarger) }
    @objc private func differentOnce() { finish(.overwriteIfDifferent) }
    @objc private func different() { finish(.overwriteIfDifferent, all: true) }
    @objc private func replace() { finish(info.source.isBrowsableFolder && info.destination.isBrowsableFolder ? .writeInto : .overwrite) }

    func present(on owner: NSWindow?, completion: @escaping (ConflictAnswer) -> Void) {
        self.completion = completion
        retainedSelf = self
        if let owner, owner.isVisible { owner.beginSheet(window) } else { window.center(); window.makeKeyAndOrderFront(nil) }
    }

    /// Legacy adapter for callers that aren't transfer workers.
    func run() -> ConflictAnswer {
        var answer = ConflictAnswer(.cancel)
        present(on: nil) {
            answer = $0; NSApp.stopModal()
        }
        NSApp.runModal(for: window)
        return answer
    }
}

private final class ConflictActionButton: NSButton {
    var primary = false
    var drawsBackground = true
    var titleTint: NSColor?
    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground { ConflictSplitView.paint(bounds.insetBy(dx: 1, dy: 1), primary: primary, highlighted: isHighlighted) }
        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: titleTint ?? (primary ? NSColor.white : Theme.windowText),
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
private final class ConflictSplitView: NSView {
    var primary = false
    var showsDivider = true
    static func paint(_ rect: CGRect, primary: Bool, highlighted: Bool = false) {
        (primary ? Theme.activeText : Theme.viewBackground).withAlphaComponent(highlighted ? 0.7 : 1).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6); path.fill()
        (primary ? Theme.activeText : Theme.frame).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func draw(_ dirtyRect: NSRect) {
        Self.paint(bounds.insetBy(dx: 1, dy: 1), primary: primary)
        if showsDivider {
            (primary ? NSColor.white.withAlphaComponent(0.3) : Theme.frame).setFill()
            CGRect(x: 128, y: 4, width: 1, height: bounds.height - 8).fill()
        }
    }
}
private final class ConflictBadge: NSView {
    let text: String
    init(text: String) { self.text = text; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Theme.compareChanged.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: Theme.compareChanged]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

private final class ConflictBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) { Theme.windowBackground.setFill(); bounds.fill() }
}
