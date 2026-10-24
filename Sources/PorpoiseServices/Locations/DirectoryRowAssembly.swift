import Foundation
import PorpoiseCore

/// Synchronously assembles visible, ordered items into rows. Callers own ordering, metadata reads and publication.
enum DirectoryRowAssembly {
    static func build(
        _ items: [FileItem], groups sections: [(title: String, items: [FileItem])]?, expanded: Set<URL>, expandsFolders: Bool,
        cancelled: () -> Bool = { false }, children: (URL) -> [FileItem]?
    ) -> (rows: [Row], groups: [ItemGroup]) {
        var rows: [Row] = []
        rows.reserveCapacity(items.count)
        var groups: [ItemGroup] = []
        func add(_ list: [FileItem], depth: Int, group: Int) {
            for item in list {
                if cancelled() { return }
                let open = expandsFolders && expanded.contains(item.url)
                rows.append(Row(item: item, depth: depth, isExpanded: open, group: group))
                if open, let kids = children(item.url) { add(kids, depth: depth + 1, group: group) }
            }
        }
        if let sections {
            for (index, section) in sections.enumerated() {
                let first = rows.count
                add(section.items, depth: 0, group: index)
                groups.append(ItemGroup(title: section.title, firstRow: first, count: rows.count - first))
            }
        } else {
            add(items, depth: 0, group: -1)
        }
        return (rows, groups)
    }
}
