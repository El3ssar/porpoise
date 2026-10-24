import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// An immutable large local-listing snapshot. No model or Settings access on its worker.
struct DirectoryModelPreparation {
    let items: [FileItem]
    let incoming: [FileItem]
    let children: [URL: [FileItem]]
    let expanded: Set<URL>
    let props: ViewProperties
    let filter: NameFilter
    let choice: SortingChoice
    let hideBackups: Bool
    let sizes: [URL: Int]
    let knownTags: [URL: [FinderTags.Tag]]
    let ordered: [FileItem]?
    var search: SearchMatches? = nil
    var retainedItems: [FileItem] = []

    struct Result {
        let top: [FileItem]
        let rows: [Row]
        let groups: [ItemGroup]
        let tags: [URL: [FinderTags.Tag]]
        let keys: [String]
        let keyCache: [URL: String]
        let alive: Set<URL>
    }

    /// Queued work can be cancelled before it starts; running work checks between preparation stages.
    /// The caller also checks its generation before publishing. No worker waits for another worker.
    private static let queue = DispatchQueue(label: "app.porpoise.directory-preparation", qos: .userInitiated, autoreleaseFrequency: .workItem)

    private final class Work {
        private let lock = NSLock()
        private var input: DirectoryModelPreparation?
        let cancellation = DiskCancellation()
        init(_ input: DirectoryModelPreparation) { self.input = input }
        func take() -> DirectoryModelPreparation? {
            lock.lock(); defer { lock.unlock() }
            let value = input
            input = nil
            return value
        }
        func cancel() {
            cancellation.cancel()
            lock.lock(); input = nil; lock.unlock()
        }
    }

    static func start(_ input: Self, completion: @escaping (Result) -> Void) -> LocationLoad {
        let work = Work(input)
        queue.async {
            guard let snapshot = work.take(), let result = snapshot.build(cancelled: { work.cancellation.isCancelled }) else { return }
            DispatchQueue.main.async {
                guard !work.cancellation.isCancelled else { return }
                completion(result)
            }
        }
        // A queued request releases its large snapshot immediately, even while an older sort finishes.
        return LocationLoad { work.cancel() }
    }

    func build(cancelled: () -> Bool = { false }) -> Result? {
        guard !cancelled() else { return nil }
        var tags = knownTags
        func visible(_ list: [FileItem], filtered: Bool) -> [FileItem] {
            let match = filtered ? filter.matcher() : nil
            return list.filter {
                (props.showHidden || !$0.isHidden) && !(hideBackups && !props.showHidden && $0.name.hasSuffix("~")) && match?($0.name) != false
            }
        }
        func tagNames(_ list: [FileItem]) -> [URL: [String]] {
            var names: [URL: [String]] = [:]
            for item in list where item.url.isFileURL {
                if cancelled() { break }
                let value = tags[item.url] ?? FinderTags.read(item.url)
                tags[item.url] = value
                if !value.isEmpty { names[item.url] = value.map(\.name) }
            }
            return names
        }
        func sort(_ list: [FileItem]) -> [FileItem] {
            ItemSorter.sort(list, props: props, choice: choice, folderSizes: sizes, tags: props.sortRole == .tags ? tagNames(list) : [:])
        }
        let top: [FileItem]
        if let ordered {
            top = ordered
        } else {
            let listing: [FileItem]
            if incoming.isEmpty {
                listing = items
            } else {
                let urls = Set(incoming.map(\.url))
                listing = items.filter { !urls.contains($0.url) } + incoming
            }
            top = sort(visible(listing, filtered: false))
        }
        guard !cancelled() else { return nil }
        let shown = filter.matcher().map { match in top.filter { match($0.name) } } ?? top
        let groupRole = props.effectiveGroupRole
        let groupTags = groupRole == .tags ? tagNames(shown) : [:]
        let sections: [(title: String, items: [FileItem])]?
        if let search, search.contents {
            let named = shown.filter { search.nameMatches($0) }
            let content = shown.filter { !search.nameMatches($0) }
            sections = [("Name matches", named), ("Content matches", content)].filter { !$0.1.isEmpty }
        } else if let role = groupRole {
            sections = ItemGrouper.groups(shown, role: role, props: props, choice: choice, folderSizes: sizes, tags: groupTags)
        } else {
            sections = nil
        }
        let assembly = DirectoryRowAssembly.build(
            shown, groups: sections, expanded: expanded, expandsFolders: props.mode == .details, cancelled: cancelled
        ) { url in
            children[url].map { sort(visible($0, filtered: true)) }
        }
        let rows = assembly.rows, groups = assembly.groups
        guard !cancelled() else { return nil }
        let urls = rows.map(\.item.url)
        let keys = FilePath.keys(urls)
        guard !cancelled() else { return nil }
        return Result(
            top: top, rows: rows, groups: groups, tags: tags, keys: keys, keyCache: Dictionary(zip(urls, keys), uniquingKeysWith: { a, _ in a }),
            alive: Set(items.map(\.url) + incoming.map(\.url) + retainedItems.map(\.url) + children.values.flatMap { $0.map(\.url) }))
    }
}
