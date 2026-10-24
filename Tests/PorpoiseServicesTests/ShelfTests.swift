import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The shelf of collected references: saved across launches, following renamed items, reporting missing ones.
@MainActor struct ShelfTests {
    let s: Scratch
    init() throws { s = try Scratch("shelf") }

    func store() -> ShelfStore { ShelfStore(file: s.path("shelves.json")) }

    /// Clear Shelf and Remove are undone with the same references (ids, bookmarks), in their order; items added since stay.
    @Test func removalsCanBeUndone() throws {
        let a = try s.file("one/a.txt", "a"), b = try s.file("one/b.txt", "b"), c = try s.file("one/c.txt", "c")
        let st = store()
        st.add([a, b, c])
        let before = st.current
        st.remove([before.items[1].id])
        #expect(st.current.items.map(\.name) == ["a.txt", "c.txt"])
        #expect(st.restore(before.items, on: before.id))
        #expect(st.current.items == before.items)
        st.clear()
        let d = try s.file("one/d.txt", "d")
        st.add([d])
        #expect(st.restore(before.items, on: before.id))
        #expect(st.current.items.map(\.name) == ["a.txt", "b.txt", "c.txt", "d.txt"])
        #expect(store().current.items.map(\.id) == st.current.items.map(\.id))  // saved
        // A shelf deleted meanwhile can't be refilled.
        st.newShelf(named: "Other")
        let gone = st.current
        st.deleteCurrent()
        #expect(!st.restore(before.items, on: gone.id))
    }

    @Test func savedAndReadBack() throws {
        let a = try s.file("one/a.txt", "a")
        let b = try s.file("two/b.txt", "b")
        let remote = URL(string: "sftp://me:secret@host/home/me/c.txt?x=1")!
        let st = store()
        #expect(st.current.name == "Shelf" && st.current.items.isEmpty)
        #expect(st.add([a, b, remote, a]) == 3)  // once each
        #expect(st.add([s.path("one/./a.txt")]) == 0)
        st.newShelf(named: "Photos")
        st.add([b])
        st.renameCurrent("Holiday")
        st.renameCurrent("  ")  // ignored
        let again = store()
        #expect(again.shelves.map(\.name) == ["Shelf", "Holiday"])
        #expect(again.currentIndex == 1)
        #expect(again.shelves[0].items.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(again.shelves[0].items[2].url.absoluteString == "sftp://me@host/home/me/c.txt")  // no password kept
        #expect(again.shelves[0].items.map(\.id) == st.shelves[0].items.map(\.id))
        // Removing a shelf never touches files; the last one is only emptied.
        again.deleteCurrent()
        #expect(again.shelves.count == 1 && again.currentIndex == 0)
        again.deleteCurrent()
        #expect(again.shelves.count == 1 && again.current.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path))
        // A damaged file starts with one empty shelf.
        try Data("{".utf8).write(to: s.path("shelves.json"))
        #expect(store().shelves.map(\.name) == ["Shelf"])
    }

    @Test func itemsAreFollowedOrReportedMissing() throws {
        let a = try s.file("one/a.txt", "a")
        let b = try s.file("one/b.txt", "b")
        let st = store()
        st.add([a, b, URL(fileURLWithPath: "/Volumes/NoSuchDisk-\(UUID().uuidString.prefix(6))/x.txt"), URL(string: "sftp://host/x")!])
        // Renamed and moved: found again, and remembered there.
        try FileManager.default.createDirectory(at: s.path("moved"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: s.path("moved/renamed.txt"))
        try FileManager.default.removeItem(at: b)
        let items = st.current.items
        #expect(st.state(of: items[0]) == .available(s.path("moved/renamed.txt").standardizedFileURL))
        #expect(st.current.items[0].url.lastPathComponent == "renamed.txt")
        #expect(st.state(of: items[1]) == .missing)
        guard case .disconnected = st.state(of: items[2]) else { Issue.record("\(st.state(of: items[2]))"); return }
        #expect(st.state(of: items[3]) == .remote(URL(string: "sftp://host/x")!))
        // An operation takes the usable ones and says which it leaves out; the missing stay on the shelf.
        let plan = st.plan(st.current.items)
        #expect(plan.urls.map(\.lastPathComponent) == ["renamed.txt", "x"])
        #expect(plan.skipped.map(\.reason).first == "Missing")
        #expect(plan.skippedText?.hasPrefix("2 items aren't available: b.txt (Missing), x.txt (“NoSuchDisk") == true)
        #expect(st.current.items.count == 4)
    }

    @Test func movesUpdateReferencesAndOrderCanChange() throws {
        let a = try s.file("one/a.txt", "a")
        let b = try s.file("one/b.txt", "b")
        let c = try s.file("one/c.txt", "c")
        let st = store()
        st.add([a, b, c])
        st.move([st.current.items[2].id], to: 0)
        #expect(st.current.items.map(\.name) == ["c.txt", "a.txt", "b.txt"])
        st.move([st.current.items[0].id], to: 3)
        #expect(st.current.items.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        let dest = try s.folder("dest")
        try FileManager.default.moveItem(at: a, to: dest.appendingPathComponent("a.txt"))
        let first = st.current.items[0]
        st.moved([a: dest.appendingPathComponent("a.txt")], sources: [first.id: a])
        #expect(st.current.items[0].url == dest.appendingPathComponent("a.txt") && st.current.items[0].id == first.id)
        st.remove([st.current.items[1].id])
        #expect(st.current.items.map(\.name) == ["a.txt", "c.txt"])
        st.clear()
        #expect(st.current.items.isEmpty)
        #expect(ShelfPlan().skippedText == nil)
    }

    @Test func moveReferencesUseReceiptsAcrossKeepBothSkipCancelAndShelfSwitches() async throws {
        let a = try s.file("src/a.txt", "a"), b = try s.file("src/b.txt", "b")
        try s.file("dst/a.txt", "old a"); try s.file("dst/b.txt", "old b")
        let st = store(); st.add([a, b])
        let entries = st.current.items, sources = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.url) })
        st.newShelf(named: "Different"); st.add([s.path("dst/a.txt")])
        let other = st.current.items
        let c = makeController(ScriptedUI(conflicts: [.init(.rename("a kept.txt")), .init(.skip)]))
        var finished = false
        c.run(.move, [a, b], to: s.path("dst"), window: nil, moved: { st.moved($0, sources: sources) }) { _ in finished = true }
        #expect(await poll { finished })
        #expect(st.current.items == other)
        #expect(st.shelves[0].items.map(\.url) == [s.path("dst/a kept.txt"), b])
        #expect(st.shelves[0].items.map(\.id) == entries.map(\.id))
        st.moved([:], sources: sources)  // A failed/cancelled job has no receipt, even if a same-named target exists.
        #expect(st.shelves[0].items[1].url == b && s.read("dst/b.txt") == "old b")
        #expect(store().shelves[0].items == st.shelves[0].items)
    }
}
