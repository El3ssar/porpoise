import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Inline rename

extension ItemListView: NSTextFieldDelegate {
    var isRenaming: Bool { renamingItem != nil }

    var renamingIndex: Int? { renamingItem.flatMap { model.index(of: $0.url) } }

    func beginRename(_ url: URL) {
        guard let i = model.index(of: url) else { return }
        commitRename()
        scrollToItem(i)
        let item = model.rows[i].item
        renamingItem = item
        let f = NSTextField(string: item.name)
        f.font = font
        f.isBordered = true
        f.bezelStyle = .squareBezel
        f.focusRingType = .none
        f.drawsBackground = true
        f.backgroundColor = Theme.fieldBackground
        f.textColor = Theme.viewText
        f.alignment = mode == .icons ? .center : .left
        f.delegate = self
        f.cell?.wraps = mode == .icons
        f.cell?.isScrollable = mode != .icons
        f.wantsLayer = true
        f.layer?.borderColor = Theme.focus.cgColor
        f.layer?.borderWidth = 1
        f.layer?.cornerRadius = 3
        addSubview(f)
        renameField = f
        positionRenameField(i)
        window?.makeFirstResponder(f)
        // Select the name without the extension, like Dolphin.
        if let editor = f.currentEditor() {
            let name = item.name as NSString
            let ext = item.isBrowsableFolder ? "" : name.pathExtension
            let len = ext.isEmpty ? name.length : name.length - (ext as NSString).length - 1
            editor.selectedRange = NSRange(location: 0, length: max(0, len))
        }
        needsDisplay = true
    }

    func positionRenameField(_ i: Int) {
        guard let f = renameField else { return }
        let tr = nameTextRect(i)
        if mode == .icons {
            let h = max(lineHeight + 6, min(tr.height, lineHeight * 3 + 6))
            f.frame = CGRect(x: tr.minX - 2, y: tr.minY, width: tr.width + 4, height: h)
        } else {
            // Like KItemListRoleEditor: as wide as the name plus some room, within the name column.
            let textW = textWidth(renamingItem?.name ?? "")
            let w = min(mode == .details ? tr.width : max(tr.width, 300), max(160, textW + 40))
            f.frame = CGRect(x: tr.minX - 3, y: tr.midY - (lineHeight + 6) / 2, width: w + 6, height: lineHeight + 6)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelRename(); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { commitRename(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitRename() }

    func commitRename() {
        guard let f = renameField, let item = renamingItem else { return }
        let name = f.stringValue
        // Clear the state first: removing the field ends editing, which calls back into this method.
        renameField = nil
        renamingItem = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        if !name.isEmpty && name != item.name { delegate?.itemList(self, rename: item, to: name) }
    }

    func cancelRename() {
        // Clear the state before removing the field: its end-of-editing callback would otherwise commit the edit.
        let f = renameField
        renameField = nil
        renamingItem = nil
        f?.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
