import AppKit
import PorpoiseCore
import PorpoiseServices

/// One comparison drives both sides. All filesystem work and tree preparation stay on a utility queue.
final class CompareModel {
    let leftRoot: URL
    let rightRoot: URL
    var options: SyncCompareOptions
    var comparison: SyncComparison?
    var outline: CompareOutline?
    var rows: [SyncDifference] = []
    var lastRebuildMilliseconds: Double = 0
    var filter: CompareFilter = .differences
    var sortRole: ItemRole = .name
    var sortAscending = true
    var sortSide: SyncSide = .left
    private var sortGeneration = 0
    var expanded = Set<String>()
    var suppressWatchUpdates = false
    var loading = false
    var showProgress = false
    var error: String?
    var elapsed: TimeInterval = 0
    var onChange: (() -> Void)?
    var watcher: SyncWatcher?
    var overrides: [String: SyncOverride] = [:]
    private var cancellation = DiskCancellation()
    private var generation = 0
    var names: (String, String) { CompareOutline.sideNames(leftRoot, rightRoot) }
    init(left: URL, right: URL, options: SyncCompareOptions = .init()) {
        leftRoot = left; rightRoot = right; self.options = options
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
            if case .success(let (c, outline)) = top {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == ticket, !token.isCancelled else { return }
                    self.comparison = c; self.outline = outline; self.rebuild()
                }
            }
            let result = Result { () throws -> (SyncComparison, CompareOutline) in
                let c = try SyncScanner.compare(left, right, options: options, cancellation: token).comparison
                return (c, CompareOutline(c))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == ticket, !token.isCancelled else { return }
                self.loading = false; self.showProgress = false; self.elapsed = CACurrentMediaTime() - start
                switch result {
                case .success(let (c, outline)): self.comparison = c; self.outline = outline
                case .failure(let error): self.error = error.localizedDescription
                }
                self.rebuild()
            }
        }
        if watcher == nil {
            watcher = SyncWatcher(roots: [leftRoot, rightRoot]) { [weak self] in
                DispatchQueue.main.async { if self?.suppressWatchUpdates == false { self?.start() } }
            }
        }
    }
    func sort(by role: ItemRole, side: SyncSide) {
        if sortRole == role && sortSide == side { sortAscending.toggle() } else { sortRole = role; sortSide = side; sortAscending = true }
        guard var outline else { return }
        sortGeneration += 1; let ticket = sortGeneration, generation = generation, ascending = sortAscending
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            outline.sort(by: role, side: side, ascending: ascending)
            DispatchQueue.main.async {
                guard let self, self.sortGeneration == ticket, self.generation == generation else { return }
                self.outline = outline; self.rebuild()
            }
        }
    }
    func rebuild() {
        let start = CACurrentMediaTime()
        rows = outline?.visible(filter: filter, expanded: expanded) ?? []; onChange?()
        lastRebuildMilliseconds = (CACurrentMediaTime() - start) * 1000
    }
    func toggle(_ flag: CompareFilter) { filter.formSymmetricDifference(flag); rebuild() }
    func expand(_ path: String) { if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }; rebuild() }
    func stop() { cancellation.cancel(); generation += 1; loading = false; showProgress = false; onChange?() }
    deinit { cancellation.cancel() }
}
