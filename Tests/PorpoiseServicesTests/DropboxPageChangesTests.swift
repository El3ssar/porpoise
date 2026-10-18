import Foundation
import Testing

@testable import PorpoiseServices

/// The indexed change page does what a scan of every cached item per entry did.
struct DropboxPageChangesTests {
    private func scanned(_ entries: [DropboxItem], cached: [DropboxItem]) -> (updates: [String: DropboxItem], removed: Set<String>) {
        var current = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var updates: [String: DropboxItem] = [:]; var removed = Set<String>()
        for entry in entries {
            if entry.tag == "deleted", let path = entry.pathLower {
                let ids = current.values.filter { $0.pathLower == path || $0.pathLower?.hasPrefix(path + "/") == true }.map(\.id)
                for id in ids { current[id] = nil; updates[id] = nil; removed.insert(id) }
            } else if entry.tag != "deleted" {
                let replaced = current.values.filter { $0.pathLower == entry.pathLower && $0.id != entry.id }.map(\.id)
                for id in replaced { current[id] = nil; updates[id] = nil; removed.insert(id) }
                current[entry.id] = entry; updates[entry.id] = entry; removed.remove(entry.id)
            }
        }
        return (updates, removed)
    }

    @Test func matchesAScanPerEntry() {
        var random = SystemRandomNumberGenerator()
        let folders = ["/a", "/a/b", "/a/b/c", "/ab", "/d", "/d/e"]
        for round in 0..<40 {
            var cached: [DropboxItem] = []
            for (n, folder) in folders.enumerated() where Bool.random(using: &random) || n == 0 {
                cached.append(DropboxItem(id: "id:dir\(n)", name: folder, tag: "folder", path: folder))
            }
            for n in 0..<60 {
                cached.append(DropboxItem(id: "id:\(n)", name: "f\(n)", path: folders.randomElement(using: &random)! + "/f\(n % 25)"))
            }
            var entries: [DropboxItem] = []
            for n in 0..<30 {
                let folder = folders.randomElement(using: &random)!
                switch Int.random(in: 0..<4, using: &random) {
                case 0: entries.append(DropboxItem(id: folder, name: "", tag: "deleted", path: folder))
                case 1: entries.append(DropboxItem(id: "id:\(Int.random(in: 0..<60, using: &random))", name: "m", path: folder + "/f\(n % 25)"))
                case 2: entries.append(DropboxItem(id: "id:new\(round)-\(n)", name: "n", path: folder + "/f\(n % 25)"))
                default: entries.append(DropboxItem(id: "id:dir\(n)", name: "d", tag: "folder", path: folder + "/sub\(n % 3)"))
                }
            }
            let expected = scanned(entries, cached: cached), got = dropboxPageChanges(entries, cached: cached)
            #expect(Dictionary(got.updates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) == expected.updates, "round \(round)")
            #expect(got.removed == expected.removed, "round \(round)")
        }
    }
}
