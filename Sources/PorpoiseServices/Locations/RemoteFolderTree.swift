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
                tree?.onChange?(self)
            }
        }

        private func update() {
            guard let listing, let tree else { return }
            // An initial failure is still retryable on the next expansion. Keep any usable previous snapshot.
            if !listing.items.isEmpty || listing.loadError == nil && !listing.isLoading {
                let old = Dictionary((children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
                children = listing.items.filter { item in
                    item.isBrowsableFolder
                        && (tree.showHidden || !item.isHidden && !item.name.hasPrefix(".")
                            || tree.visiblePath.contains { RemoteFolderTree.sameLocation($0, item.url) })
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { item in
                    let node = old[item.url] ?? Node(url: item.url, name: item.name, tree: tree)
                    node.name = item.name
                    return node
                }
            }
            tree.advanceReveal()
            tree.onChange?(self)
        }

        fileprivate func path(to target: URL) -> [Node]? {
            if RemoteFolderTree.sameLocation(target, url) { return [self] }
            for child in children ?? [] {
                if let path = child.path(to: target) { return [self] + path }
            }
            return nil
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
    public private(set) var selected: Node?
    private var revealChain: [URL] = []
    private var visiblePath: [URL] = []
    private var revealRefreshes: Set<URL> = []
    private var advancingReveal = false
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

    public func find(_ url: URL) -> Node? { path(to: url)?.last }

    /// The already-listed path also survives a temporary disconnect, when provider ancestry is unavailable.
    public func path(to url: URL) -> [Node]? { root.path(to: url) }

    /// Reveals the shared breadcrumb chain, including this tree's stable root and the target. Listings arrive
    /// asynchronously; each completed page advances the pending chain without inventing missing parent nodes.
    public func reveal(_ chain: [URL]) {
        guard let first = chain.first, Self.sameLocation(first, root.url) else { return }
        revealChain = chain
        visiblePath = chain
        revealRefreshes = []
        selected = nil
        advanceReveal()
        onChange?(root)
    }

    private func advanceReveal() {
        guard !advancingReveal, !revealChain.isEmpty else { return }
        advancingReveal = true
        defer { advancingReveal = false }
        var node = root!
        for target in revealChain.dropFirst() {
            node.expand()
            if let next = node.children?.first(where: { Self.sameLocation($0.url, target) }) {
                node = next
            } else {
                if !node.isLoading, node.message == nil, revealRefreshes.insert(node.url).inserted { node.refresh() }
                return
            }
        }
        selected = node
        revealChain = []
    }

    /// Directory slashes are presentation; query variants stay distinct unless their provider confirms identity.
    public static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL, includingQuery: Bool = true) -> String {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
            if !includingQuery { parts.query = nil }
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
            while parts.percentEncodedPath.count > 1 && parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
            return parts.string ?? url.absoluteString
        }
        if key(a) == key(b) { return true }
        // A service may omit redundant navigation context in its breadcrumb ancestors. Keep the path scope so
        // aliases in different branches remain separate; only the provider can say whether query variants match.
        guard key(a, includingQuery: false) == key(b, includingQuery: false), let provider = RemoteFS.provider(for: a) as? CloudFileProvider else {
            return false
        }
        return provider.sameItem(a, b)
    }

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
