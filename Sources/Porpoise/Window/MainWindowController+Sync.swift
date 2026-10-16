import AppKit
import PorpoiseCore
import PorpoiseServices

extension MainWindowController {
    func openSyncForComparison(
        leftRoot: URL, rightRoot: URL, options: SyncCompareOptions = .init(), comparison: SyncComparison? = nil, keepAutomatically: Bool = false
    ) {
        guard let window else { return }
        var newPair = SavedSync(left: leftRoot, right: rightRoot); newPair.visibleInSidebar = false
        var pair = SyncCoordinator.shared.pair(left: leftRoot, right: rightRoot) ?? newPair
        if keepAutomatically { pair.automatic = true }
        pair.method = options.method; pair.timestampTolerance = options.timestampTolerance
        // Comparison-owned custom filters are retained without silently adding system exclusions to an existing result.
        if comparison != nil {
            var remaining = Set(options.exclusions); pair.presets = []
            for preset in SyncExclusionPreset.allCases where Set(preset.patterns).isSubset(of: remaining) {
                pair.presets.insert(preset); remaining.subtract(preset.patterns)
            }
            pair.customExclusions = remaining.sorted()
        }
        SyncSheetController(pair: pair, owner: window, comparison: comparison).present()
    }
}

enum SyncUI {
    static func activity(forLeft left: URL, right: URL) -> Activity? { SyncCoordinator.shared.activity(left: left, right: right) }
}
