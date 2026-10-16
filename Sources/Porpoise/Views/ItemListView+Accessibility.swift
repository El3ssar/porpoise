import AppKit
import PorpoiseCore
import PorpoiseServices

/// VoiceOver for the custom-drawn file view: a list whose children are the items on screen (a folder can hold
/// tens of thousands; VoiceOver scrolls the view, which brings the next ones in). Each item reads its name, then its
/// kind and size, says whether it's selected, and opens on "press".
extension ItemListView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? {
        model.location.lastPathComponent
    }

    override func accessibilityChildren() -> [Any]? { accessibilityRows(in: visibleRect) }
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
        return list.comparisonAccessibilityLabel?(index) ?? item.name
    }

    override func accessibilityValue() -> Any? {
        guard let it = item else { return nil }
        if list?.comparisonAccessibilityLabel != nil { return nil }
        return it.isBrowsableFolder ? it.typeDescription : "\(it.typeDescription), \(FileFormat.size(it.size))"
    }

    override func isAccessibilitySelected() -> Bool { list?.model.selection.contains(url) ?? false }

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
