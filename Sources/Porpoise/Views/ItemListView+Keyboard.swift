import AppKit
import PorpoiseCore
import PorpoiseServices

/// Virtual key codes handled by the item view.
private enum Key {
    static let returnKey = 36, space = 49, backspace = 51, escape = 53, enter = 76
    static let home = 115, pageUp = 116, forwardDelete = 117, end = 119, pageDown = 121
    static let left = 123, right = 124, down = 125, up = 126
}

/// Type-ahead keeps extending the typed prefix while keys come within this interval.
private let typeAheadTimeout: TimeInterval = 1.0

// MARK: - Keyboard

extension ItemListView {
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.characters ?? ""
        let shift = mods.contains(.shift)
        switch Int(event.keyCode) {
        case Key.up where mods == [.command]: NSApp.sendAction(#selector(MainWindowController.goUp(_:)), to: nil, from: self); return
        case Key.down where mods == [.command]: openSelection(); return  // Finder's Cmd+↓
        case Key.up: moveCurrent(.up, extend: shift); return
        case Key.down: moveCurrent(.down, extend: shift); return
        case Key.left:
            if mode == .details, mods.isEmpty, collapseOrGoToParent() { return }
            moveCurrent(.left, extend: shift); return
        case Key.right:
            if mode == .details, mods.isEmpty, expandCurrent() { return }
            moveCurrent(.right, extend: shift); return
        case Key.home: moveCurrent(.home, extend: shift); return
        case Key.end: moveCurrent(.end, extend: shift); return
        case Key.pageUp: moveCurrent(.pageUp, extend: shift); return
        case Key.pageDown: moveCurrent(.pageDown, extend: shift); return
        case Key.returnKey, Key.enter:
            if mods.isEmpty { openSelection(); return }
        case Key.escape:
            if selectionModeActive, let c = delegate as? ViewContainer {
                c.selectionMode = false
                return
            }
            if !model.selection.isEmpty { model.selection = []; needsDisplay = true }
            return
        case Key.backspace where mods.isEmpty:
            // ⌫ = Back (Dolphin's Backspace), only while the view has focus.
            NSApp.sendAction(#selector(MainWindowController.goBack(_:)), to: nil, from: self)
            return
        case Key.forwardDelete where mods.isEmpty || mods == [.shift]:
            // fn+⌫ (Delete) = Move to Trash, Shift+Delete = Delete permanently.
            NSApp.sendAction(
                mods.isEmpty ? #selector(MainWindowController.moveToTrash(_:)) : #selector(MainWindowController.deleteItem(_:)),
                to: nil, from: self)
            return
        case Key.space:
            if mods.isEmpty && !isTypingAhead { delegate?.itemListQuickLook(self); return }
            if mods == [.control], let c = model.currentURL {
                if model.selection.contains(c) { model.selection.remove(c) } else { model.selection.insert(c) }
                needsDisplay = true
                return
            }
        default: break
        }
        if mods == [.option], event.charactersIgnoringModifiers == "." {
            // Alt+. = Show Hidden Files (Dolphin)
            NSApp.sendAction(#selector(MainWindowController.toggleHiddenFiles(_:)), to: nil, from: self)
            return
        }
        if mods.isEmpty, chars == "/", !isTypingAhead {
            NSApp.sendAction(#selector(MainWindowController.showFilterBar(_:)), to: nil, from: self)
            return
        }
        if mods.subtracting(.shift).isEmpty, let ch = chars.first, !ch.isNewline,
            ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        {
            typeAheadSearch(chars, backwards: shift && chars.count == 1 && !ch.isLetter)
            return
        }
        super.keyDown(with: event)
    }

    /// Details ←: collapse the current folder, or go to its parent row. False without a current item.
    private func collapseOrGoToParent() -> Bool {
        guard let c = model.currentURL, let i = model.index(of: c) else { return false }
        let r = model.rows[i]
        if r.isExpanded {
            model.setExpanded(c, false)
        } else if r.depth > 0, let parent = (0..<i).last(where: { model.rows[$0].depth < r.depth }) {
            select(model.rows[parent].item.url)
        }
        return true
    }

    /// Details →: expand the current folder. False without a current item.
    private func expandCurrent() -> Bool {
        guard let c = model.currentURL, let i = model.index(of: c) else { return false }
        if model.rows[i].item.isBrowsableFolder && !model.rows[i].isExpanded && expanderWidth > 0 { model.setExpanded(c, true) }
        return true
    }

    func openSelection() {
        let items = model.selectedItems
        if !items.isEmpty {
            delegate?.itemList(self, open: items, inNewTab: false)
        } else if let c = model.currentURL, let i = model.index(of: c) {
            delegate?.itemList(self, open: [model.rows[i].item], inNewTab: false)
        }
    }

    // MARK: Moving the current item

    private enum Move { case up, down, left, right, home, end, pageUp, pageDown }

    private func moveCurrent(_ m: Move, extend: Bool) {
        guard !model.rows.isEmpty else { return }
        if frames.count != model.rows.count { computeLayout() }
        let count = model.rows.count
        var n: Int
        if let c = model.currentURL.flatMap({ model.index(of: $0) }) {
            let pageRows = max(1, Int(visibleHeight / max(1, frames.first?.height ?? 20)) - 1)
            switch (mode, m) {
            case (.icons, .up): n = iconsRowNeighbor(of: c, below: false) ?? 0
            case (.icons, .down): n = iconsRowNeighbor(of: c, below: true) ?? c
            case (.icons, .left), (.details, .left): n = c - 1
            case (.icons, .right), (.details, .right): n = c + 1
            case (.compact, .left): n = compactColumnNeighbor(of: c, right: false) ?? 0
            case (.compact, .right): n = compactColumnNeighbor(of: c, right: true) ?? count - 1
            case (_, .up): n = c - 1
            case (_, .down): n = c + 1
            case (_, .home): n = 0
            case (_, .end): n = count - 1
            case (.icons, .pageUp): n = c - columns * max(1, pageRows / 3)
            case (.icons, .pageDown): n = c + columns * max(1, pageRows / 3)
            case (_, .pageUp): n = c - pageRows
            case (_, .pageDown): n = c + pageRows
            }
            if mode == .icons, m == .pageDown, n >= count {
                // Last row: jump to the last item only if it is on a lower row.
                n = frames[count - 1].minY > frames[c].minY ? count - 1 : c
            }
            n = max(0, min(count - 1, n))
        } else {
            n = (m == .end) ? count - 1 : 0
        }
        let url = model.rows[n].item.url
        if extend, let anchor = model.anchorURL ?? model.currentURL, let a = model.index(of: anchor) {
            model.selection = Set((min(a, n)...max(a, n)).map { model.rows[$0].item.url })
            if model.anchorURL == nil { model.anchorURL = anchor }
        } else {
            model.selection = [url]
            model.anchorURL = url
        }
        model.currentURL = url
        scrollToItem(n)
        needsDisplay = true
    }

    /// Icons ↑/↓: the item of the visual row above/below that is nearest in x. Rows restart under each group
    /// header, so stepping by `columns` would land in the wrong column. Nil when there is no such row.
    private func iconsRowNeighbor(of c: Int, below: Bool) -> Int? {
        let y = frames[c].minY, x = frames[c].minX
        let step = below ? 1 : -1
        var j = c
        while frames.indices.contains(j) && frames[j].minY == y { j += step }
        guard frames.indices.contains(j) else { return nil }
        let rowY = frames[j].minY
        var best = j
        while frames.indices.contains(j) && frames[j].minY == rowY {
            if abs(frames[j].minX - x) < abs(frames[best].minX - x) { best = j }
            j += step
        }
        return best
    }

    /// Compact ←/→: the item of the column left/right that is nearest in y. Groups start new (possibly short) columns,
    /// so stepping by `rowsPerColumn` would land on the wrong row. Nil when there is no such column.
    private func compactColumnNeighbor(of c: Int, right: Bool) -> Int? {
        let x = frames[c].minX, y = frames[c].minY
        let step = right ? 1 : -1
        var j = c
        while frames.indices.contains(j) && frames[j].minX == x { j += step }
        guard frames.indices.contains(j) else { return nil }
        let colX = frames[j].minX
        var best = j
        while frames.indices.contains(j) && frames[j].minX == colX {
            if abs(frames[j].minY - y) < abs(frames[best].minY - y) { best = j }
            j += step
        }
        return best
    }

    func select(_ url: URL, scroll: Bool = true) {
        model.selection = [url]
        model.currentURL = url
        model.anchorURL = url
        if scroll, let i = model.index(of: url) { scrollToItem(i) }
        needsDisplay = true
    }

    func scrollToItem(_ i: Int) {
        guard i < frames.count else { return }
        let r = mode == .details ? frames[i].insetBy(dx: -Self.sidePadding, dy: -2) : frames[i].insetBy(dx: -4, dy: -4)
        scrollToVisible(r)
    }

    // MARK: Type-ahead

    /// A type-ahead prefix is being typed (Space and / then belong to it).
    private var isTypingAhead: Bool { !typeAhead.isEmpty && Date().timeIntervalSince(typeAheadTime) <= typeAheadTimeout }

    private func typeAheadSearch(_ s: String, backwards: Bool) {
        let newSearch = !isTypingAhead
        if newSearch { typeAhead = "" }
        typeAheadTime = Date()
        typeAhead += s
        // Dolphin (KItemListKeyboardSearchManager): the same key again cycles through the items starting with it,
        // and a new search starts after the current item, so typing "a" on an "a…" item moves on.
        let first = typeAhead.first.map(String.init) ?? ""
        let sameKey = typeAhead.count > 1 && typeAhead.allSatisfy { String($0) == first }
        let needle = (sameKey ? first : typeAhead).lowercased()
        let rows = model.rows
        let n = rows.count
        guard n > 0 else { return }
        let current = model.currentURL.flatMap { model.index(of: $0) }
        let fromNext = (newSearch || sameKey) && current != nil
        let start = ((current ?? 0) + (fromNext ? (backwards ? n - 1 : 1) : 0)) % n
        for k in 0..<n {
            let j = backwards ? (start - k + n) % n : (start + k) % n
            if rows[j].item.name.lowercased().hasPrefix(needle) {
                select(rows[j].item.url)
                return
            }
        }
    }
}
