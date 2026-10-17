import Foundation
import PorpoiseCore

/// Main-thread folder tree for remote locations. Every expansion uses the browser's DirectoryModel and provider
/// listing cache; probing for a disclosure triangle never starts a request.
public final class RemoteFolderTree {
    public final class Node {
        public let url: URL
        public private(set) var name: String
        public private(set) var children: [Node]?
        public private(set) var isExpanded = false
        public var isLoading: Bool { listing?.isLoading == true || listing?.isRefreshing == true }
        public var message: String? { listing?.loadError }
        public var isExpandable: Bool { children.map { !$0.isEmpty } ?? true }
        private var listing: DirectoryModel?
        private weak var tree: RemoteFolderTree?

        fileprivate init(url: URL, name: String, tree: RemoteFolderTree) {
            self.url = url; self.name = name; self.tree = tree
        }

        public func expand() {
            isExpanded = true
            if let listing {
                if listing.loadError != nil { listing.reload(); tree?.onChange?(self) }
                return
            }
            let model = DirectoryModel(location: url, prefetchFolders: false)
            listing = model
            model.onChange = { [weak self] in self?.update() }
            model.onLoaded = { [weak self] in self?.update() }
            model.reload()
            tree?.onChange?(self)
        }

        public func collapse() {
            isExpanded = false
            for child in children ?? [] { child.collapse() }
        }

        fileprivate func refresh() {
            if isExpanded {
                listing?.reload()
                tree?.onChange?(self)
            } else {
                // A collapsed branch is read again only on expansion; no speculative network work.
                listing = nil
                children = nil
            }
        }

        private func update() {
            guard let listing, let tree else { return }
            // An initial failure is still retryable on the next expansion. Keep any usable previous snapshot.
            if !listing.items.isEmpty || listing.loadError == nil && !listing.isLoading {
                let old = Dictionary((children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
                children = listing.items.filter { $0.isBrowsableFolder && (tree.showHidden || !$0.isHidden && !$0.name.hasPrefix(".")) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { item in
                        let node = old[item.url] ?? Node(url: item.url, name: item.name, tree: tree)
                        node.name = item.name
                        return node
                    }
            }
            tree.onChange?(self)
        }

        fileprivate func find(_ target: URL) -> Node? {
            if target == url { return self }
            return children?.lazy.compactMap { $0.find(target) }.first
        }

        fileprivate func refreshBranch() {
            let previous = children ?? []
            refresh()
            if isExpanded { for child in previous { child.refreshBranch() } }
        }
    }

    public private(set) var root: Node!
    public var onChange: ((Node) -> Void)?
    public var showHidden = false
    private var observers: [NSObjectProtocol] = []
    private var refreshPending = false

    public init(url: URL) {
        root = Node(url: url, name: RemoteFS.displayName(for: url), tree: self)
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: CloudAccounts.remoteChanged, object: nil, queue: .main) { [weak self] note in
                guard let self, let account = note.object as? String,
                    account == self.root.url.host || account == CloudAccounts.shared.backend?.accountID(for: self.root.url)
                else { return }
                self.scheduleRefresh()
            })
        observers.append(
            center.addObserver(forName: CloudAccounts.changed, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            })
        observers.append(
            center.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: .main) { [weak self] note in
                guard let self, let paths = note.userInfo?["paths"] as? Set<String>, self.contains(paths: paths, node: self.root) else { return }
                self.scheduleRefresh()
            })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    public func find(_ url: URL) -> Node? { root.find(url) }

    /// Coalesces all pages of one change notification burst and refreshes only expanded branches.
    public func reload() { root.refreshBranch() }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.reload()
        }
    }

    private func contains(paths: Set<String>, node: Node) -> Bool {
        paths.contains(node.url.path) || (node.children ?? []).contains { contains(paths: paths, node: $0) }
    }
}
