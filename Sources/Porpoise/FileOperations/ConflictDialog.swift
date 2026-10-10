import AppKit
import PorpoiseCore
import PorpoiseServices

/// KIO's RenameDialog: what to do with an item whose name exists at the destination.
final class ConflictDialog: NSObject, NSTextFieldDelegate {
    let info: ConflictInfo
    let kind: FileOperationKind
    private var result = ConflictAnswer(.cancel)
    private let window: NSWindow
    private let nameField = NSTextField()
    private let applyAll = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
    private var renameButton: NSButton!

    init(info: ConflictInfo, kind: FileOperationKind) {
        self.info = info
        self.kind = kind
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let bothDirs = info.source.isBrowsableFolder && info.destination.isBrowsableFolder
        window.title = bothDirs ? "Folder Already Exists" : "File Already Exists"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBackground
        let v = window.contentView!
        let header = NSTextField(
            wrappingLabelWithString: bothDirs
                ? "Would you like to merge the contents of “\(info.source.name)” into “\(info.destination.url.deletingLastPathComponent().lastPathComponent)”?"
                : "This action will overwrite the destination.")
        header.font = Theme.boldFont
        header.frame = CGRect(x: 20, y: 286, width: 580, height: 34)
        v.addSubview(header)

        func pane(_ item: FileItem, title: String, x: CGFloat) {
            let box = NSView(frame: CGRect(x: x, y: 130, width: 280, height: 150))
            box.wantsLayer = true
            box.layer?.backgroundColor = Theme.viewBackground.cgColor
            box.layer?.cornerRadius = 5
            box.layer?.borderColor = Theme.frame.cgColor
            box.layer?.borderWidth = 1
            let t = NSTextField(labelWithString: title); t.font = Theme.boldFont; t.frame = CGRect(x: 10, y: 122, width: 260, height: 18)
            let img = NSImageView(frame: CGRect(x: 10, y: 40, width: 72, height: 72))
            img.image = Thumbnails.shared.thumbnail(for: item, size: 72) ?? Icons.shared.image(for: item, size: 72)
            let lines = [
                item.url.path,
                item.isBrowsableFolder ? "Folder" : FileFormat.size(item.size),
                item.modificationDate.map { "Modified: " + FileFormat.relativeDate($0) } ?? "",
            ]
            for (i, l) in lines.enumerated() {
                let f = NSTextField(labelWithString: l)
                f.font = i == 0 ? Theme.smallFont : Theme.font
                f.lineBreakMode = .byTruncatingMiddle
                f.frame = CGRect(x: 90, y: 92 - CGFloat(i) * 22, width: 180, height: 18)
                box.addSubview(f)
            }
            box.addSubview(t)
            box.addSubview(img)
            v.addSubview(box)
        }
        pane(info.source, title: "Source", x: 20)
        pane(info.destination, title: "Destination", x: 320)

        // Comparison hint (KIO: "The source is more recent", "smaller by …", "identical").
        var hints: [String] = []
        if let s = info.source.modificationDate, let d = info.destination.modificationDate {
            if s > d { hints.append("The source is more recent.") } else if s < d { hints.append("The destination is more recent.") }
        }
        if !bothDirs {
            let diff = info.source.size - info.destination.size
            if diff > 0 {
                hints.append("The source is bigger by \(FileFormat.size(diff)).")
            } else if diff < 0 {
                hints.append("The source is smaller by \(FileFormat.size(-diff)).")
            } else if info.source.modificationDate == info.destination.modificationDate {
                hints.append("The files are identical.")
            }
        }
        let hint = NSTextField(labelWithString: hints.joined(separator: " "))
        hint.textColor = Theme.windowTextInactive
        hint.frame = CGRect(x: 20, y: 104, width: 580, height: 18)
        v.addSubview(hint)

        let renameLabel = NSTextField(labelWithString: "Rename:")
        renameLabel.frame = CGRect(x: 20, y: 72, width: 60, height: 20)
        nameField.stringValue = info.destination.name
        nameField.frame = CGRect(x: 84, y: 70, width: 340, height: 24)
        nameField.delegate = self
        let suggest = NSButton(title: "Suggest New Name", target: self, action: #selector(suggest))
        suggest.frame = CGRect(x: 430, y: 66, width: 170, height: 30)
        [renameLabel, nameField, suggest].forEach(v.addSubview)

        applyAll.frame = CGRect(x: 20, y: 22, width: 120, height: 20)
        v.addSubview(applyAll)

        var x: CGFloat = 600
        func button(_ title: String, _ sel: Selector, key: String = "") -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.keyEquivalent = key
            b.sizeToFit()
            b.frame.size.width += 12
            x -= b.frame.width + 6
            b.frame.origin = CGPoint(x: x, y: 16)
            v.addSubview(b)
            return b
        }
        _ = button("Cancel", #selector(cancel), key: "\u{1b}")
        _ = button("Skip", #selector(skip))
        if bothDirs {
            _ = button("Write Into", #selector(writeInto), key: "\r")
        } else {
            _ = button("Overwrite Older", #selector(overwriteOlder))
            _ = button("Overwrite", #selector(overwrite), key: "\r")
        }
        renameButton = button("Rename", #selector(rename))
        renameButton.isEnabled = false
    }

    func controlTextDidChange(_ obj: Notification) {
        renameButton.isEnabled = FileActions.isValidName(nameField.stringValue) && nameField.stringValue != info.destination.name
    }

    @objc private func suggest() {
        nameField.stringValue = info.suggestedName
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    private func finish(_ r: ConflictResolution) {
        result = ConflictAnswer(r, applyToAll: applyAll.state == .on)
        NSApp.stopModal()
        window.orderOut(nil)
    }

    @objc private func cancel() { finish(.cancel) }
    @objc private func skip() { finish(.skip) }
    @objc private func overwrite() { finish(.overwrite) }
    @objc private func overwriteOlder() { finish(.overwriteIfOlder) }
    @objc private func writeInto() { finish(.writeInto) }
    @objc private func rename() { finish(.rename(nameField.stringValue)) }

    func run() -> ConflictAnswer {
        window.center()
        NSApp.runModal(for: window)
        return result
    }
}
