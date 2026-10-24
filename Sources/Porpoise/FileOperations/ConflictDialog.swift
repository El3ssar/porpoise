import AppKit
import PorpoiseCore
import PorpoiseServices
import QuickLookThumbnailing

/// The type scale, shortened for the text styles in this file.
private typealias FontSize = Tokens.FontSize

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
    private let methods: [TransferCompareMethod] = [.sizeAndDate, .sizeOnly, .content]

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
        let destinationFolder = info.destination.url.deletingLastPathComponent()
        // Google Drive folders are ids in their URLs: their names come from the listing ("My Drive").
        let destinationName =
            PlacesModel.isCloud(destinationFolder)
            ? Activity.name(destinationFolder)
            : LinkedBrowsing.sideNames(info.source.url.deletingLastPathComponent(), destinationFolder).1
        let bothFolders = info.source.isBrowsableFolder && info.destination.isBrowsableFolder
        let delta = info.source.modificationDate.flatMap { source in info.destination.modificationDate.map { source.timeIntervalSince($0) } }
        // No date on either side: neither newer nor older (Return then skips).
        let newer = delta.map { $0 > info.comparisonOptions.timestampTolerance } ?? false
        let older = delta.map { $0 < -info.comparisonOptions.timestampTolerance } ?? false
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
        } else if delta == nil {
            hint = "A modification date is unavailable. Compare contents before replacing."
        } else if info.source.size == info.destination.size {
            hint = "They look identical: same size and date. Compare contents to check every byte."
        } else {
            hint = "The items have different sizes."
        }
        let hintHeight = ceil(
            (hint as NSString).boundingRect(
                with: CGSize(width: 580, height: 40), options: .usesLineFragmentOrigin,
                attributes: [.font: NSFont.systemFont(ofSize: FontSize.callout)]
            ).height)
        let height = max(16, hintHeight)
        window.setContentSize(CGSize(width: 620, height: 358 + height))
        _ = label(
            (bothFolders ? "A folder named “\(info.source.name)”" : "“\(info.source.name)”")
                + " already exists in \(destinationName)",
            CGRect(x: 20, y: 324 + height, width: 450, height: 18), size: 13, weight: .semibold)
        _ = label(hint, CGRect(x: 20, y: 321, width: 580, height: height), secondary: true)
        card(
            info.destination, heading: "In \(destinationName)", x: 20, newer: older,
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
        method.font = .systemFont(ofSize: FontSize.small)
        method.controlSize = .small
        method.frame = CGRect(x: 238, y: 103, width: 234, height: 24)
        method.addItems(withTitles: Self.methodTitles(tolerance: info.comparisonOptions.timestampTolerance))
        method.selectItem(at: methods.firstIndex(of: info.comparisonOptions.method) ?? 0)
        method.target = self; method.action = #selector(methodChanged)
        counts.frame = CGRect(x: 32, y: 107, width: 202, height: 16)
        counts.font = .systemFont(ofSize: FontSize.small); counts.textColor = Theme.windowTextInactive
        window.contentView!.addSubview(counts)
        methodChanged()
        method.toolTip = "Size & date compares metadata; Contents reads every byte."
        window.contentView!.addSubview(method)
        let total = info.remainingConflicts ?? 1
        let rule = NSButton(title: total > 1 ? "Apply to All \(total)" : "Apply", target: self, action: #selector(different))
        rule.bezelStyle = .push
        rule.frame = CGRect(x: 482, y: 113, width: 108, height: 32)
        window.contentView!.addSubview(rule)
        applyAll.title = total > 1 ? "Do this for the other \(total - 1) conflicts" : "Do this for later conflicts in this transfer"
        if total > 1 { _ = label("Conflict 1 of \(total)", CGRect(x: 470, y: 325 + height, width: 130, height: 18), size: 11, secondary: true) }
        applyAll.font = .systemFont(ofSize: FontSize.small)
        applyAll.frame = CGRect(x: 20, y: 63, width: 386, height: 22)
        window.contentView!.addSubview(applyAll)
        // AppKit's own buttons: the default one in the accent, keyboard focus shown, Escape and Return as macOS has them.
        func button(_ title: String, x: CGFloat, width: CGFloat, action: Selector, key: String = "") -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .push
            button.controlSize = .large
            button.frame = CGRect(x: x, y: 16, width: width, height: 36)
            button.keyEquivalent = key
            window.contentView!.addSubview(button)
            return button
        }
        _ = button(kind == .move ? "Stop Moving" : "Stop Copying", x: 14, width: 124, action: #selector(cancel), key: "\u{1b}")
        // Return replaces only a same-kind item that is older: a folder is never replaced by a file (nor a file by a
        // folder) just by pressing Return.
        let replacesByDefault = Self.replacesByDefault(
            newer: newer, bothFolders: bothFolders, sameKind: info.source.isDirectory == info.destination.isDirectory)
        _ = button("Skip", x: 266, width: 76, action: #selector(skip), key: replacesByDefault ? "" : "\r")
        let keep = button("Keep Both", x: 342, width: 104, action: #selector(keepBoth), key: "d")
        keep.keyEquivalentModifierMask = .command
        keep.toolTip = "Save as “\(info.suggestedName)”"
        let title =
            bothFolders
            ? "Merge"
            : older
                ? "Replace with Older"
                : info.destination.isDirectory != info.source.isDirectory
                    ? (info.destination.isDirectory ? "Replace Folder" : "Replace File") : "Replace"
        _ = button(title, x: 446, width: bothFolders ? 160 : 124, action: #selector(replace), key: replacesByDefault ? "\r" : "")
        // The conditional rules, in a menu beside Replace.
        let rules = button("", x: 570, width: 36, action: #selector(choices))
        rules.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Conditional replacement rules")
        rules.imagePosition = .imageOnly
        rules.toolTip = "Conditional replacement rules"
        rules.isHidden = bothFolders
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
        if larger { size.textColor = Theme.transferChanged }
        let formatter = DateFormatter()
        formatter.locale = .current; formatter.dateFormat = "d MMM yyyy, HH:mm"
        let dateText = item.modificationDate.map { formatter.string(from: $0) } ?? "Date unavailable"
        let date = label(dateText, CGRect(x: x + 86, y: 217, width: newer ? 124 : 176, height: 16), size: 10.5, secondary: !newer)
        date.lineBreakMode = .byTruncatingTail; date.toolTip = dateText
        if newer { date.textColor = Theme.transferChanged }
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
        // A palette theme gives the controls its look and the default button its accent (the native theme keeps macOS's).
        Theme.dress(window)
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

    /// Whether Return replaces: folders merge; otherwise only a newer item of the same kind.
    static func replacesByDefault(newer: Bool, bothFolders: Bool, sameKind: Bool) -> Bool { bothFolders || newer && sameKind }

    /// The comparison methods, the date tolerance as the transfer uses it ("2 s", "1 min").
    static func methodTitles(tolerance: TimeInterval) -> [String] {
        let t = tolerance >= 60 && tolerance.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(tolerance / 60)) min" : "\(Int(tolerance.rounded())) s"
        return ["Size & date · \(t)", "Size only", "Contents"]
    }
}

private final class ConflictBadge: NSView {
    let text: String
    init(text: String) { self.text = text; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Theme.transferChanged.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: FontSize.caption, weight: .semibold), .foregroundColor: Theme.transferChanged,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

final class ConflictBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) { Theme.windowBackground.setFill(); bounds.fill() }
}
