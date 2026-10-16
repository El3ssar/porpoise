import AppKit
import PorpoiseCore
import PorpoiseServices

/// One comparison drives both sides. All filesystem work and tree preparation stay on a utility queue.
final class CompareModel {
    static var defaultOptions: SyncCompareOptions {
        .init(exclusions: [".DS_Store", "._*", ".Spotlight-V100", ".Trashes", "Thumbs.db", "desktop.ini", ".porpoise-trash"])
    }
    let leftRoot: URL
    let rightRoot: URL
    var options: SyncCompareOptions
    var comparison: SyncComparison?
    var outline: CompareOutline? { didSet { needsSort = true } }
    private var needsSort = true
    var rows: [SyncDifference] = []
    var lastRebuildMilliseconds: Double = 0
    var rowsVersion = 0
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
    var overrides: [String: SyncOverride] = [:]
    private var cancellation = DiskCancellation()
    private var generation = 0
    let names: (String, String)
    init(left: URL, right: URL, options: SyncCompareOptions = CompareModel.defaultOptions) {
        leftRoot = left; rightRoot = right; self.options = options; names = CompareOutline.sideNames(left, right)
    }
    func start() {
        cancellation.cancel(); cancellation = DiskCancellation(); generation += 1
        let token = cancellation, ticket = generation, start = CACurrentMediaTime(), options = options
        loading = true; showProgress = false; error = nil; onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == ticket, self.loading else { return }
            self.showProgress = true; self.onChange?()
        }
        let left = leftRoot, right = rightRoot
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Top-level rows arrive first, with directory subtrees explicitly incomplete until the full pass.
            let top = Result { () throws -> (SyncComparison, CompareOutline) in
                let l = try SyncScanner.scan(left, options: options, maxDepth: 1, cancellation: token)
                let r = try SyncScanner.scan(right, options: options, maxDepth: 1, cancellation: token)
                let c = SyncComparator.compare(l, r, options: options)
                return (c, CompareOutline(c))
            }
            if case .success(let (c, outline)) = top, !c.complete {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == ticket, !token.isCancelled else { return }
                    releaseComparisonValuesLater((self.comparison, self.outline))
                    self.comparison = c; self.outline = outline; self.rebuild()
                }
            }
            let result = Result { () throws -> (SyncComparison, CompareOutline) in
                // A shallow pass is already complete for flat folders. Reuse it rather than scanning,
                // comparing and publishing the same potentially large set of files twice.
                if case .success(let pair) = top, pair.0.complete { return pair }
                let c = try SyncScanner.compare(left, right, options: options, cancellation: token).comparison
                return (c, CompareOutline(c))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == ticket, !token.isCancelled else { return }
                self.loading = false; self.showProgress = false; self.elapsed = CACurrentMediaTime() - start
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
                let watcher = SyncWatcher(roots: [left, right]) { [weak self] in
                    DispatchQueue.main.async { if self?.suppressWatchUpdates == false { self?.start() } }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.watcher = watcher; self?.startingWatcher = false
                }
            }
        }
    }
    func sort(by role: ItemRole, side: SyncSide) {
        if sortRole == role && sortSide == side { sortAscending.toggle() } else { sortRole = role; sortSide = side; sortAscending = true }
        needsSort = true; rebuild()
    }
    func rebuild() {
        let start = CACurrentMediaTime()
        presentationGeneration += 1
        let ticket = presentationGeneration, outline = outline, filter = filter, expanded = expanded, previousPaths = rowPaths
        let needsSort = needsSort, role = sortRole, side = sortSide, ascending = sortAscending
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
            let changedPaths = paths != previousPaths
            DispatchQueue.main.async {
                guard let self, self.presentationGeneration == ticket else { return }
                if needsSort { self.outline = outline; self.needsSort = false }
                if changedPaths { self.rowsVersion += 1 }
                releaseComparisonValuesLater((self.rows, self.rowIndices, self.rowPaths))
                self.rows = rows; self.rowIndices = indices; self.rowPaths = paths
                self.visibleLeftBytes = left; self.visibleRightBytes = right
                self.onChange?(); self.lastRebuildMilliseconds = (CACurrentMediaTime() - start) * 1000
            }
        }
    }
    func toggle(_ flag: CompareFilter) { filter.formSymmetricDifference(flag); rebuild() }
    func expand(_ path: String) { if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }; rebuild() }
    func stop() { cancellation.cancel(); generation += 1; loading = false; showProgress = false; onChange?() }
    deinit {
        cancellation.cancel()
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
