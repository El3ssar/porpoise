import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct RenameFieldTests {
    init() { _ = NSApplication.shared }

    private func list(_ names: [String], mode: ViewMode) throws -> (ItemListView, NSWindow) {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = names.map { FileItem(url: scratch.url.appendingPathComponent($0), name: $0, isDirectory: false) }
        model.props.mode = mode
        let view = ItemListView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // closed by the test, which still holds it
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
        model.onChange = { [weak view] in view?.relayout() }
        view.computeLayout()
        // A fractional zoom: the size the W-176 review saw the box drift at.
        view.previewZoom(53.2, commitAfter: nil)
        view.commitZoom()
        return (view, window)
    }

    @Test func theIconsBoxFitsTheNameAndSitsOnItsLabel() throws {
        let (view, window) = try list(["Alpha-0.txt", "Alpha a rather long file name that wraps over lines.txt"], mode: .icons)
        defer { window.close() }
        let short = try #require(view.model.rows.firstIndex { $0.item.name == "Alpha-0.txt" })
        view.beginRename(view.model.rows[short].item.url)
        let field = try #require(view.renameField)
        let label = view.nameTextRect(short)
        // One line of text plus the bezel, starting where the label's text starts (less the bezel inset).
        #expect(abs(field.frame.height - (view.lineHeight + 6)) <= 1)
        #expect(abs(field.frame.minY - (label.minY - 3)) <= 0.5)
        // Typing a longer name grows the box, up to three lines.
        field.stringValue = String(repeating: "longer name ", count: 12)
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(field.frame.height > view.lineHeight * 2)
        #expect(field.frame.height <= view.lineHeight * CGFloat(ItemListView.renameMaxLines) + 7)
        view.cancelRename()
    }

    @Test func listModesCenterTheBoxOnTheRow() throws {
        for mode in [ViewMode.compact, .details, .columns] {
            let (view, window) = try list(["Alpha-0.txt"], mode: mode)
            view.beginRename(view.model.rows[0].item.url)
            let field = try #require(view.renameField)
            #expect(abs(field.frame.midY - view.nameTextRect(0).midY) <= 0.5)
            view.cancelRename()
            window.close()
        }
    }
}
