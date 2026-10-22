import AppKit
import PorpoiseCore
import PorpoiseServices

/// VoiceOver for the custom-drawn file view: a list whose children are the items on screen (a folder can hold
/// tens of thousands; VoiceOver scrolls the view, which brings the next ones in), with the folder's full count. Each
/// item reads its name, then what the view shows about it (kind, size, the columns, tags, cut or hidden), can be
/// selected (VO-Space), shows its context menu (VO-Shift-M) and opens on "press".
extension ItemListView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? {
        model.location.lastPathComponent
    }

    override func accessibilityChildren() -> [Any]? { accessibilityRows(in: visibleRect) }
    /// Every item in the folder, not only those on screen.
    override func accessibilityRowCount() -> Int { model.rows.count }
    override func accessibilityVisibleChildren() -> [Any]? { accessibilityRows(in: visibleRect) }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityRows(in: visibleRect).filter { $0.isAccessibilitySelected() }
    }

    /// Selection or the current item changed: VoiceOver reads the new one.
    func accessibilitySelectionChanged() {
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        if let c = model.currentURL, let i = model.index(of: c), i < frames.count {
            NSAccessibility.post(element: accessibilityElement(at: i), notification: .focusedUIElementChanged)
        }
    }

    /// The menu ⇧F10 shows and where: the current item's at the item, else the folder's at the top left.
    func keyboardMenu() -> (menu: NSMenu, at: CGPoint)? {
        if let c = model.currentURL, let i = model.index(of: c), i < frames.count, let m = accessibilityMenu(for: i) {
            return (m, CGPoint(x: frames[i].midX, y: frames[i].midY))
        }
        guard let m = delegate?.itemList(self, menuFor: nil) else { return nil }
        return (m, CGPoint(x: visibleRect.minX + 20, y: visibleRect.minY + 20))
    }

    /// The menu ⇧F10 opened, while it's open (for tests to look at it and close it).
    nonisolated(unsafe) static weak var keyboardMenuShown: NSMenu?

    func showKeyboardMenu() {
        guard let (menu, at) = keyboardMenu() else { return }
        Self.keyboardMenuShown = menu
        menu.popUp(positioning: nil, at: at, in: self)
    }

    /// The context menu for item `i`, selecting it first unless it's already part of the selection.
    func accessibilityMenu(for i: Int) -> NSMenu? {
        guard i < model.rows.count else { return nil }
        selecting.contextClick(i)
        needsDisplay = true
        return delegate?.itemList(self, menuFor: model.rows[i].item)
    }

    private func accessibilityRows(in rect: CGRect) -> [ItemAccessibilityElement] {
        if frames.count != model.rows.count { computeLayout() }
        return candidateIndexes(in: rect).map { accessibilityElement(at: $0) }
    }
    private func accessibilityElement(at index: Int) -> ItemAccessibilityElement {
        let url = model.rows[index].item.url
        if accessibleItems.count > 500 {
            let visible = Set(candidateIndexes(in: visibleRect).map { model.rows[$0].item.url })
            accessibleItems = accessibleItems.filter { visible.contains($0.key) }
        }
        let element = accessibleItems[url] ?? ItemAccessibilityElement(list: self, index: index)
        element.index = index; accessibleItems[url] = element
        return element
    }
}

/// One item of an `ItemListView` for VoiceOver.
final class ItemAccessibilityElement: NSAccessibilityElement, NSAccessibilityElementProtocol {
    private weak var list: ItemListView?
    var index: Int
    private let url: URL

    init(list: ItemListView, index: Int) {
        self.list = list
        self.index = index
        url = list.model.rows[index].item.url
        super.init()
        setAccessibilityParent(list)
        setAccessibilityRole(.row)
        setAccessibilitySubrole(.outlineRow); setAccessibilityEnabled(true)
    }

    private var item: FileItem? {
        guard let list, index < list.model.rows.count, list.model.rows[index].item.url == url else { return nil }
        return list.model.rows[index].item
    }

    override func accessibilityIdentifier() -> String { url.absoluteString }

    override func accessibilityLabel() -> String? {
        guard let list, let item else { return nil }
        return item.name
    }

    /// Kind and size, then what the view shows: its columns (Details) or extra lines, tags, and dimmed states.
    override func accessibilityValue() -> Any? {
        guard let list, let it = item else { return nil }
        let model = list.model
        var parts = [it.isBrowsableFolder ? it.typeDescription : "\(it.typeDescription), \(FileFormat.size(it.size))"]
        for role in model.props.roles(for: list.mode) where ![.name, .type, .size, .tags].contains(role) {
            let text = model.text(for: role, of: it)
            if !text.isEmpty { parts.append("\(role.title) \(text)") }
        }
        let tags = model.shownTags(for: it).map(\.name)
        if !tags.isEmpty { parts.append((tags.count == 1 ? "Tag " : "Tags ") + tags.joined(separator: ", ")) }
        if it.isAliasFile { parts.append("alias") } else if it.isSymlink { parts.append("symbolic link") }
        if list.cutURLs.contains(url) { parts.append("cut") }
        if it.isHidden { parts.append("hidden") }
        if let mark = list.editMark(it) { parts.append(mark.note(CloudAccounts.shared.providerTitle(for: url))) }
        return parts.joined(separator: ", ")
    }

    override func isAccessibilitySelected() -> Bool { list?.model.selection.contains(url) ?? false }

    /// VO-Space: selects this item alone (as a click does); deselecting removes it from the selection.
    override func setAccessibilitySelected(_ selected: Bool) {
        guard let list, item != nil else { return }
        if selected {
            list.select(url)
        } else {
            list.model.selection.remove(url)
            list.needsDisplay = true
        }
        list.accessibilitySelectionChanged()
    }

    /// VO-Shift-M: the item's context menu, at the item, as a right-click on it shows it.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let list, item != nil, index < list.frames.count, let menu = list.accessibilityMenu(for: index) else { return false }
        let frame = list.frames[index]
        menu.popUp(positioning: nil, at: CGPoint(x: frame.midX, y: frame.midY), in: list)
        return true
    }

    override func accessibilityFrameInParentSpace() -> NSRect {
        guard let list, index < list.frames.count else { return .zero }
        return list.frames[index]
    }

    override func accessibilityFrame() -> NSRect {
        guard let list, let window = list.window, index < list.frames.count else { return .zero }
        return window.convertToScreen(list.convert(list.frames[index], to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let list, let it = item else { return false }
        list.delegate?.itemList(list, open: [it], inNewTab: false)
        return true
    }

    override func isEqual(_ object: Any?) -> Bool { (object as? ItemAccessibilityElement)?.url == url }
    override var hash: Int { url.hashValue }
}
