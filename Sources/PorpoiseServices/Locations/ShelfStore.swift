import Foundation
import PorpoiseCore

/// One reference on a shelf: a local file (followed through renames and moves by a bookmark) or a remote location.
public struct ShelfItem: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Where it was last seen.
    public var url: URL
    /// Finds a local item again after it was renamed or moved.
    public var bookmark: Data?
    public var added = Date()

    public init(url: URL) {
        self.url = ShelfStore.withoutSecrets(url)
        bookmark = url.isFileURL ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
    }

    public var name: String { url.lastPathComponent }
}

/// A named collection of references gathered from anywhere (folders, searches, servers).
public struct Shelf: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var items: [ShelfItem] = []

    public init(name: String) { self.name = name }
}

/// Whether a shelf item can be used now.
public enum ShelfItemState: Equatable, Sendable {
    /// There (possibly at a new place, if it was renamed or moved).
    case available(URL)
    /// On a server: reached when an operation runs.
    case remote(URL)
    /// Its disk isn't connected.
    case disconnected(volume: String)
    /// Deleted (or moved where it can't be found).
    case missing

    public var url: URL? {
        switch self {
        case .available(let u), .remote(let u): return u
        default: return nil
        }
    }

    /// "Missing", "“Backup” isn't connected"; nil when usable.
    public var problem: String? {
        switch self {
        case .available, .remote: return nil
        case .disconnected(let v): return "“\(v)” isn't connected"
        case .missing: return "Missing"
        }
    }
}

/// What an operation on shelf items will touch, and what it leaves out (and why). Nothing is dropped silently.
public struct ShelfPlan: Equatable, Sendable {
    public var urls: [URL] = []
    public var skipped: [(name: String, reason: String)] = []

    public static func == (a: ShelfPlan, b: ShelfPlan) -> Bool {
        a.urls == b.urls && a.skipped.map(\.name) == b.skipped.map(\.name) && a.skipped.map(\.reason) == b.skipped.map(\.reason)
    }

    /// "2 items aren't available: a.txt (Missing), b.txt (“Backup” isn't connected)."
    public var skippedText: String? {
        guard !skipped.isEmpty else { return nil }
        let list = skipped.prefix(5).map { "\($0.name) (\($0.reason))" }.joined(separator: ", ")
        return "\(skipped.count) \(skipped.count == 1 ? "item isn't" : "items aren't") available: \(list)\(skipped.count > 5 ? "…" : "")."
    }
}

/// The shelves (Panels › Shelf), saved in Application Support/Porpoise/shelves.json. Main thread only.
public final class ShelfStore {
    public static let shared = ShelfStore(file: ShelfStore.defaultFile)
    public static let changed = Notification.Name("PorpoiseShelfChanged")
    static let fileVersion = 1

    public let file: URL
    public private(set) var shelves: [Shelf]
    /// The shelf the panel shows.
    public private(set) var currentIndex = 0

    public var current: Shelf { shelves[currentIndex] }

    static var defaultFile: URL {
        if Settings.isTesting { return FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-test-shelves-\(getpid()).json") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise/shelves.json")
    }

    private struct Saved: Codable {
        var version: Int
        var current: Int
        var shelves: [Shelf]
    }

    public init(file: URL) {
        self.file = file
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d), s.version == Self.fileVersion, !s.shelves.isEmpty {
            shelves = s.shelves
            currentIndex = min(max(0, s.current), s.shelves.count - 1)
        } else {
            shelves = [Shelf(name: "Shelf")]
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(Saved(version: Self.fileVersion, current: currentIndex, shelves: shelves)) { try? d.write(to: file, options: .atomic) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: Items

    /// Adds references to the current shelf (those already on it stay where they are). Returns how many were new.
    @discardableResult
    public func add(_ urls: [URL]) -> Int {
        var known = Set(current.items.map { Self.key($0.url) })
        var added = 0
        for u in urls where known.insert(Self.key(u)).inserted {
            shelves[currentIndex].items.append(ShelfItem(url: u))
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    public func remove(_ ids: Set<UUID>) {
        shelves[currentIndex].items.removeAll { ids.contains($0.id) }
        save()
    }

    public func clear() {
        shelves[currentIndex].items = []
        save()
    }

    /// Moves items to `index` in the list (drag to reorder).
    public func move(_ ids: Set<UUID>, to index: Int) {
        var items = current.items
        let moving = items.filter { ids.contains($0.id) }
        let before = items[..<min(index, items.count)].filter { ids.contains($0.id) }.count
        items.removeAll { ids.contains($0.id) }
        items.insert(contentsOf: moving, at: max(0, min(items.count, index - before)))
        shelves[currentIndex].items = items
        save()
    }

    // MARK: Shelves

    public func select(_ index: Int) {
        guard shelves.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        save()
    }

    /// A new empty shelf, made current.
    public func newShelf(named name: String) {
        shelves.append(Shelf(name: name.isEmpty ? "Shelf \(shelves.count + 1)" : name))
        currentIndex = shelves.count - 1
        save()
    }

    public func renameCurrent(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        shelves[currentIndex].name = name
        save()
    }

    /// Removes the current shelf (its references only, never the files); the last one is emptied instead.
    public func deleteCurrent() {
        if shelves.count == 1 {
            clear()
            return
        }
        shelves.remove(at: currentIndex)
        currentIndex = min(currentIndex, shelves.count - 1)
        save()
    }

    // MARK: Where items are now

    /// Finds an item: at its path, else through its bookmark (renamed or moved: the new place is remembered).
    public func state(of item: ShelfItem) -> ShelfItemState {
        let s = Self.resolve(item)
        if case .available(let u) = s, u != item.url, let i = current.items.firstIndex(where: { $0.id == item.id }) {
            shelves[currentIndex].items[i].url = u
            shelves[currentIndex].items[i].bookmark = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            save()
        }
        return s
    }

    static func resolve(_ item: ShelfItem) -> ShelfItemState {
        guard item.url.isFileURL else { return .remote(item.url) }
        if FileJob.itemExists(at: item.url) { return .available(item.url) }
        if let b = item.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: b, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                FileJob.itemExists(at: u)
            {
                return .available(u.standardizedFileURL)
            }
        }
        // On a disk that isn't there: disconnected, not missing.
        let parts = item.url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/" + parts[2]) {
            return .disconnected(volume: parts[2])
        }
        return .missing
    }

    /// The usable locations of `items`, and the others with the reason they're left out.
    public func plan(_ items: [ShelfItem]) -> ShelfPlan {
        var p = ShelfPlan()
        for item in items {
            let s = state(of: item)
            if let u = s.url { p.urls.append(u) } else { p.skipped.append((item.name, s.problem ?? "Unavailable")) }
        }
        return p
    }

    /// After a move, the references follow their items to `folder`.
    public func moved(_ items: [ShelfItem], to folder: URL) {
        for item in items {
            guard let i = current.items.firstIndex(where: { $0.id == item.id }) else { continue }
            let u = folder.appendingPathComponent(item.url.lastPathComponent)
            if folder.isFileURL ? FileJob.itemExists(at: u) : true {
                shelves[currentIndex].items[i] = ShelfItem(url: u)
                shelves[currentIndex].items[i].id = item.id
            }
        }
        save()
    }

    // MARK: Helpers

    private static func key(_ u: URL) -> String { u.isFileURL ? u.standardizedFileURL.path : withoutSecrets(u).absoluteString }

    /// Remote locations are kept without a password (or query): the shelf file is not a keychain.
    static func withoutSecrets(_ url: URL) -> URL {
        guard !url.isFileURL, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.password = nil
        c.query = nil
        return c.url ?? url
    }
}
