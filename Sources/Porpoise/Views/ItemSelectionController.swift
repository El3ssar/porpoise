import AppKit
import PorpoiseServices

/// How clicks, Shift and Cmd, and moves of the current item change a view's selection: the folder view and the
/// Applications grid both go through it. The selection, the current item and the Shift anchor are the model's; the
/// views work out which item a click or an arrow key means.
struct ItemSelectionController {
    let model: DirectoryModel

    /// A click on the item at `i`: Shift selects the range from the anchor (Cmd+Shift adds it to the selection), Cmd
    /// adds or removes the item, a plain click on an item not selected selects only it. The item becomes current.
    func click(_ i: Int, modifiers: NSEvent.ModifierFlags) {
        let url = model.rows[i].item.url
        if modifiers.contains(.shift), let a = model.anchorURL.flatMap({ model.index(of: $0) }) {
            let urls = range(a, i)
            model.selection = modifiers.contains(.command) ? model.selection.union(urls) : urls
        } else if modifiers.contains(.command) {
            if model.selection.contains(url) { model.selection.remove(url) } else { model.selection.insert(url) }
            model.anchorURL = url
        } else if !model.selection.contains(url) {
            model.selection = [url]
            model.anchorURL = url
        }
        model.currentURL = url
    }

    /// A plain click that ends (no drag) on the item at `i`, which was selected before: of several selected items, only
    /// it stays. It becomes the anchor.
    func clickEnded(_ i: Int, wasSelected: Bool) {
        guard i < model.rows.count else { return }
        let url = model.rows[i].item.url
        if wasSelected && model.selection.count > 1 { model.selection = [url] }
        model.anchorURL = url
    }

    /// A click on no item: without Cmd or Shift it clears the selection.
    func clickBackground(modifiers: NSEvent.ModifierFlags) {
        if !modifiers.contains(.command) && !modifiers.contains(.shift) { model.selection = [] }
    }

    /// A secondary click on the item at `i` (nil: on no item): an item not selected becomes the selection, and current.
    func contextClick(_ i: Int?) {
        guard let i else { model.selection = []; return }
        let url = model.rows[i].item.url
        if !model.selection.contains(url) { model.selection = [url] }
        model.currentURL = url
    }

    /// Moves the current item to `n` (an arrow key, Home, End, a page): `extend` (Shift) selects the range from the
    /// anchor, else only the item, which becomes the anchor.
    func move(to n: Int, extend: Bool) {
        let url = model.rows[n].item.url
        if extend, let anchor = model.anchorURL ?? model.currentURL, let a = model.index(of: anchor) {
            model.selection = range(a, n)
            if model.anchorURL == nil { model.anchorURL = anchor }
        } else {
            model.selection = [url]
            model.anchorURL = url
        }
        model.currentURL = url
    }

    /// Adds or removes one item, making it the current item and the anchor for Shift ranges.
    func toggle(_ url: URL) {
        if model.selection.contains(url) { model.selection.remove(url) } else { model.selection.insert(url) }
        model.currentURL = url
        model.anchorURL = url
    }

    /// Selects only `url`, current and the anchor.
    func select(_ url: URL) {
        model.selection = [url]
        model.currentURL = url
        model.anchorURL = url
    }

    private func range(_ a: Int, _ b: Int) -> Set<URL> { Set((min(a, b)...max(a, b)).map { model.rows[$0].item.url }) }
}
