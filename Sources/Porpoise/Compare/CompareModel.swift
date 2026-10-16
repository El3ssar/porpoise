import AppKit
import PorpoiseCore
import PorpoiseServices

/// One comparison drives both sides. All filesystem work and tree preparation stay on a utility queue.
final class CompareModel {
    static var defaultOptions: SyncCompareOptions {
        .init(exclusions: [".DS_Store", "._*", ".Spotlight-V100", ".Trashes", "Thumbs.db", "desktop.ini", ".porpoise-trash"])
    }
    private(set) var leftRoot: URL
    private(set) var rightRoot: URL
    var options: SyncCompareOptions
    var comparison: SyncComparison?
    var outline: CompareOutline? { didSet { needsSort = true } }
    private var needsSort = true
    var rows: [SyncDifference] = []
    var lastRebuildMilliseconds: Double = 0
    var rowsVersion = 0
    var detailsVersion = 0
    var leftDetails = CompareDetailsPresentation([], root: URL(fileURLWithPath: "/"), side: .left, expanded: [])
    var rightDetails = CompareDetailsPresentation([], root: URL(fileURLWithPath: "/"), side: .right, expanded: [])
    var rowIndices: [String: Int] = [:]
    var rowPaths: [String] = []
    var visibleLeftBytes: Int64 = 0
    var visibleRightBytes: Int64 = 0
    private var presentationGeneration = 0
    var filter: CompareFilter = .differences
    var sortRole: ItemRole = .name
    var sortAscending = true
    var sortSide: SyncSide = .left
    var expanded = Set<String>()
    var suppressWatchUpdates = false
    var loading = false
    var showProgress = false
    var error: String?
    var elapsed: TimeInterval = 0
    var onChange: (() -> Void)?
    var watcher: SyncWatcher?
    private var startingWatcher = false
    private var active = true
    var overrides: [String: SyncOverride] = [:]
    private let refresh = ComparisonRefresh()
    private(set) var names: (String, String)
    func reanchorNames(left: URL, right: URL) { names = CompareOutline.sideNames(left, right) }
    init(left: URL, right: URL, options: SyncCompareOptions = CompareModel.defaultOptions) {
        leftRoot = left; rightRoot = right; self.options = options
        names = CompareOutline.sideNames(left, right)
        refresh.onStart = { [weak self] request in self?.beginScan(request) }
    }
    private(set) var scanCount = 0
    private(set) var refreshing = false
    var presentsScanProgress: Bool { loading && !refreshing }
    private let scanQueue = DispatchQueue(label: "porpoise.compare.scan", qos: .utility)
    func navigate(left: URL, right: URL) {
        guard left != leftRoot || right != rightRoot else { return }
        refresh.stop(); presentationGeneration += 1
        leftRoot = left; rightRoot = right
        watcher?.stop(); watcher = nil; startingWatcher = false
        expanded = []; overrides = [:]
        // Old rows belong to another location; same-location watcher refreshes keep their selection and scroll.
        releaseComparisonValuesLater((comparison, outline))
        comparison = nil; outline = nil
        refresh.schedule(left: left, right: right)
        onChange?()
    }
    func start() {
        active = true; presentationGeneration += 1
        refresh.schedule(left: leftRoot, right: rightRoot, delay: 0)
    }
    private func beginScan(_ request: ComparisonRefresh.Request) {
        let token = request.cancellation, start = CACurrentMediaTime(), options = options
        scanCount += 1; refreshing = comparison != nil
        loading = true; showProgress = false; error = nil; onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.refresh.accepts(request), self.loading, !self.refreshing else { return }
            self.showProgress = true; self.onChange?()
        }
        let left = request.left, right = request.right
        scanQueue.async { [weak self] in
            // Top-level rows arrive first, with directory subtrees explicitly incomplete until the full pass.
            let top = Result { () throws -> (SyncComparison, CompareOutline) in
                let l = try CompareBrowserScan.scan(left, options: options, maxDepth: 1, cancellation: token)
                let r = try CompareBrowserScan.scan(right, options: options, maxDepth: 1, cancellation: token)
                let c = SyncComparator.compare(l, r, options: options)
                return (c, CompareOutline(c))
            }
            if case .success(let (c, outline)) = top, !c.complete {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.refresh.accepts(request), !token.isCancelled, !self.refreshing else { return }
                    releaseComparisonValuesLater((self.comparison, self.outline))
                    self.comparison = c; self.outline = outline; self.rebuild()
                }
            }
            let result = Result { () throws -> (SyncComparison, CompareOutline) in
                // A shallow pass is already complete for flat folders. Reuse it rather than scanning,
                // comparing and publishing the same potentially large set of files twice.
                if case .success(let pair) = top, pair.0.complete { return pair }
                let l = try CompareBrowserScan.scan(left, options: options, cancellation: token)
                let r = try CompareBrowserScan.scan(right, options: options, cancellation: token)
                let c = SyncComparator.compare(l, r, options: options)
                return (c, CompareOutline(c))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refresh.accepts(request), !token.isCancelled else { return }
                self.loading = false; self.refreshing = false; self.showProgress = false; self.elapsed = CACurrentMediaTime() - start
                switch result {
                case .success(let (c, outline)):
                    releaseComparisonValuesLater((self.comparison, self.outline))
                    self.comparison = c; self.outline = outline
                case .failure(let error): self.error = error.localizedDescription
                }
                self.rebuild()
            }
        }
        if watcher == nil && !startingWatcher {
            startingWatcher = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let watcher = SyncWatcher(roots: [left, right], debounce: 0.5) { [weak self] in
                    DispatchQueue.main.async {
                        if let self, self.active, self.leftRoot == left, self.rightRoot == right, !self.suppressWatchUpdates { self.start() }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.leftRoot == left, self.rightRoot == right else { watcher.stop(); return };
                    self.watcher = watcher; self.startingWatcher = false
                }
            }
        }
    }
    func invalidateSort() { needsSort = true; rebuild() }
    func sort(by role: ItemRole, side: SyncSide) {
        if sortRole == role && sortSide == side { sortAscending.toggle() } else { sortRole = role; sortSide = side; sortAscending = true }
        needsSort = true; rebuild()
    }
    func rebuild() {
        let start = CACurrentMediaTime()
        presentationGeneration += 1
        let ticket = presentationGeneration, outline = outline, filter = filter, expanded = expanded, previousPaths = rowPaths
        let needsSort = needsSort, role = sortRole, side = sortSide, ascending = sortAscending
        let leftRoot = leftRoot, rightRoot = rightRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outline = outline
            if needsSort { outline?.sort(by: role, side: side, ascending: ascending) }
            let rows = outline?.visible(filter: filter, expanded: expanded) ?? []
            var indices: [String: Int] = [:], paths: [String] = [], left: Int64 = 0, right: Int64 = 0
            indices.reserveCapacity(rows.count); paths.reserveCapacity(rows.count)
            for (index, row) in rows.enumerated() {
                indices[row.path] = index; paths.append(row.path)
                if row.left?.kind == .file { left += row.left?.size ?? 0 }
                if row.right?.kind == .file { right += row.right?.size ?? 0 }
            }
            let leftDetails = CompareDetailsPresentation(
                rows, root: leftRoot, side: .left, expanded: expanded, folderCounts: outline?.childCounts[.left] ?? [:])
            let rightDetails = CompareDetailsPresentation(
                rows, root: rightRoot, side: .right, expanded: expanded, folderCounts: outline?.childCounts[.right] ?? [:])
            let changedPaths = paths != previousPaths
            DispatchQueue.main.async {
                guard let self, self.presentationGeneration == ticket else { return }
                if needsSort { self.outline = outline; self.needsSort = false }
                if changedPaths { self.rowsVersion += 1 }
                releaseComparisonValuesLater((self.rows, self.rowIndices, self.rowPaths))
                self.rows = rows; self.rowIndices = indices; self.rowPaths = paths
                releaseComparisonValuesLater((self.leftDetails, self.rightDetails))
                self.leftDetails = leftDetails; self.rightDetails = rightDetails; self.detailsVersion += 1
                self.visibleLeftBytes = left; self.visibleRightBytes = right
                self.onChange?(); self.lastRebuildMilliseconds = (CACurrentMediaTime() - start) * 1000
            }
        }
    }
    func toggle(_ flag: CompareFilter) { filter.formSymmetricDifference(flag); rebuild() }
    func expand(_ path: String) { if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }; rebuild() }
    func stop() {
        active = false; watcher?.stop(); watcher = nil; startingWatcher = false; refresh.stop()
        presentationGeneration += 1; loading = false; showProgress = false; onChange?()
    }
    deinit {
        refresh.stop()
        // Replacing a large Compare surface must not destroy its trees and dictionaries in an
        // animation frame. These are value data; AppKit views still tear down on the main thread.
        releaseComparisonValuesLater((comparison, outline, rows, rowIndices, rowPaths, watcher))
    }
}

private func releaseComparisonValuesLater<T>(_ values: T) {
    // Retain until this main-thread stack has dropped its references, then release on the worker.
    DispatchQueue.main.async {
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(values) {} }
    }
}
