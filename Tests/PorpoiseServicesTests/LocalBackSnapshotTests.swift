import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings) struct LocalBackSnapshotTests {
    /// Holds publication after the real LocalSource worker has enumerated and identified the folder.
    @MainActor private final class Gate {
        var held: Set<URL> = []
        var pending: [URL: [() -> Void]] = [:]
        var loads: [URL: Int] = [:]
        var failures: [URL: LocationLoadError] = [:]
        var extraKeys: [URL: String] = [:]

        func install(on model: DirectoryModel) {
            model.sourceFactory = { [weak self] url, _ in
                let source = LocalSource(location: url)
                source.loadForTesting = { [weak self] folder, expanded, deliver in
                    guard let self else { return LocationLoad() }
                    self.loads[folder, default: 0] += 1
                    return LocalSource(location: folder).load(folder, expanded: expanded) { [weak self] listing in
                        guard let self else { return }
                        var value = listing
                        value.entryKeys.merge(self.extraKeys) { _, new in new }
                        if let failure = self.failures[folder] {
                            value.items = []; value.entryKeys = [:]; value.localIdentity = nil; value.error = failure
                        }
                        let publish = { deliver(value) }
                        if self.held.contains(folder) { self.pending[folder, default: []].append(publish) } else { publish() }
                    }
                }
                return source
            }
        }

        func release(_ folder: URL) {
            held.remove(folder)
            let deliveries = pending.removeValue(forKey: folder) ?? []
            for deliver in deliveries { deliver() }
        }
    }

    private func configure() {
        Settings.shared.folderSizeMode = .none
        Settings.shared.showGitStatus = false
        Settings.shared.dynamicView = false
        var style = ViewProperties(); style.mode = .details
        ViewStyleStore().common = style
    }

    private func settled(_ model: DirectoryModel, at url: URL) async throws {
        try #require(await eventually { model.location == url && !model.isLoading && !model.isRefreshing })
    }

    @Test func cachedRowsPaintBeforeTheAlwaysFreshListingAndReconcileDiskChanges() async throws {
        configure()
        let scratch = try Scratch("local-back")
        let a = try scratch.folder("a"), b = try scratch.folder("b")
        let removed = try scratch.file("a/removed.txt"), renamed = try scratch.file("a/before.txt")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload()
        try await settled(model, at: a)
        model.setLocation(b)
        try await settled(model, at: b)
        #expect(model.localSnapshotRowsForTesting == 2)
        try FileManager.default.removeItem(at: removed)
        let after = a.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: renamed, to: after)
        let added = try scratch.file("a/added.txt")
        gate.held.insert(a)
        defer { gate.release(a) }
        var loaded = 0
        model.onLoaded = { loaded += 1 }
        model.setLocation(a)
        try #require(await eventually { !model.isLoading && model.isRefreshing && gate.pending[a]?.isEmpty == false })
        #expect(model.rows.map(\.item.name).sorted() == ["before.txt", "removed.txt"])
        #expect(loaded == 1 && (gate.loads[a] ?? 0) >= 2 && model.pendingLocalSnapshotRowsForTesting == 0)
        // A user may select an old row while the authoritative refresh is still running.
        model.selection = [removed]; model.currentURL = removed
        gate.release(a)
        try await settled(model, at: a)
        let actualPaths = model.rows.map { $0.item.url.path }.sorted()
        let expectedPaths = [added.path, after.path].sorted()
        #expect(actualPaths == expectedPaths)
        #expect(model.selection.isEmpty && model.currentURL == nil && loaded >= 2)
        // The old A payload was consumed; the one retained slot contains the departed empty B.
        #expect(model.localSnapshotRowsForTesting == 0)
    }

    @Test(arguments: [false, true])
    func navigationFromCachedCallbacksCannotOverwriteTheNewLoad(viaLoaded: Bool) async throws {
        configure()
        let scratch = try Scratch("local-back-reentry")
        let a = try scratch.folder("a"), b = try scratch.folder("b"), c = try scratch.folder("c")
        try scratch.file("a/old.txt"); try scratch.file("c/current.txt")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload(); try await settled(model, at: a)
        model.setLocation(b); try await settled(model, at: b)
        gate.held.insert(a)
        defer { gate.release(a) }
        var redirected = false
        let redirect = {
            if model.location == a, model.isRefreshing, !model.rows.isEmpty {
                redirected = true; model.setLocation(c)
            }
        }
        if viaLoaded { model.onLoaded = redirect } else { model.onChange = redirect }
        model.setLocation(a)
        try await settled(model, at: c)
        #expect(redirected && model.rows.map(\.item.name) == ["current.txt"])
        gate.release(a)
        await Task.yield()
        #expect(model.location == c && model.rows.map(\.item.name) == ["current.txt"] && !model.isRefreshing)
    }

    @Test func cachedSourceRowCallbackCannotChangeANewerLoadsPhase() async throws {
        configure()
        let scratch = try Scratch("cached-source-reentry")
        let a = try scratch.folder("a"), b = try scratch.folder("b")
        try scratch.file("b/current.txt")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        let cached = ReentrantCachedSource(location: a)
        gate.install(on: model)
        let localFactory = model.sourceFactory
        model.sourceFactory = { folder, enabled in
            if folder == a { return cached }
            return localFactory(folder, enabled)
        }
        gate.held.insert(b)
        defer { gate.release(b) }
        model.onChange = { if model.location == a, !model.rows.isEmpty { model.setLocation(b) } }
        model.reload()
        try #require(await eventually { gate.pending[b]?.isEmpty == false })
        #expect(model.location == b && model.rows.isEmpty && model.isLoading && !model.isRefreshing)
        #expect(cached.loads == 0)
        gate.release(b); try await settled(model, at: b)
        #expect(model.rows.map(\.item.name) == ["current.txt"])
    }

    @Test func aSupersededIdentityCheckCannotPaintItsSnapshot() async throws {
        configure()
        let scratch = try Scratch("local-back-stale-validation")
        let a = try scratch.folder("a"), b = try scratch.folder("b"), c = try scratch.folder("c")
        try scratch.file("a/old.txt"); try scratch.file("c/current.txt")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload(); try await settled(model, at: a)
        model.setLocation(b); try await settled(model, at: b)
        var validations: [() -> Void] = []
        model.validateLocalSnapshot = { folder, identity, complete in
            LocalSource.validate(folder, identity: identity) { matches in validations.append { complete(matches) } }
        }
        gate.held.insert(a)
        defer { gate.release(a) }
        model.setLocation(a)
        try #require(await eventually { validations.count == 1 && gate.pending[a]?.isEmpty == false })
        #expect(model.rows.isEmpty && model.isRefreshing)
        model.setLocation(c); try await settled(model, at: c)
        validations[0](); gate.release(a)
        #expect(model.location == c && model.rows.map(\.item.name) == ["current.txt"])
        #expect(model.pendingLocalSnapshotRowsForTesting == 0)
    }

    @Test(arguments: ["style", "filter", "sorting", "backup", "folderSize"])
    func incompatiblePreferencesWaitForFreshRows(change: String) async throws {
        configure()
        let scratch = try Scratch("local-back-incompatible")
        let a = try scratch.folder("a"), b = try scratch.folder("b")
        try scratch.file("a/item.txt")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload(); try await settled(model, at: a)
        model.setLocation(b); try await settled(model, at: b)
        switch change {
        case "style": var style = ViewStyleStore().common; style.mode = .icons; ViewStyleStore().common = style
        case "filter": model.filter = NameFilter(text: "item")
        case "sorting": Settings.shared.sortingChoice = .caseSensitive; model.rebuild()
        case "backup": Settings.shared.hideBackupFiles.toggle(); model.rebuild()
        default: Settings.shared.folderSizeDepth += 1
        }
        try await settled(model, at: b)
        gate.held.insert(a)
        defer { gate.release(a) }
        model.setLocation(a)
        try #require(await eventually { gate.pending[a]?.isEmpty == false })
        #expect(model.rows.isEmpty && model.isLoading && !model.isRefreshing)
        gate.release(a); try await settled(model, at: a)
        #expect(model.rows.map(\.item.name) == ["item.txt"])
    }

    @Test(arguments: ["retarget", "replace", "permission"])
    func physicalIdentityAndAccessFailuresNeverPaintOldRows(change: String) async throws {
        configure()
        let scratch = try Scratch("local-back-identity")
        let original = try scratch.folder("original"), other = try scratch.folder("other"), b = try scratch.folder("b")
        try scratch.file("original/old.txt"); try scratch.file("other/new.txt")
        let a = change == "retarget" ? try scratch.symlink("alias", to: "original") : original
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload(); try await settled(model, at: a)
        model.setLocation(b); try await settled(model, at: b)
        if change == "retarget" {
            try FileManager.default.removeItem(at: a)
            try FileManager.default.createSymbolicLink(at: a, withDestinationURL: other)
        } else if change == "replace" {
            try FileManager.default.moveItem(at: original, to: scratch.path("moved"))
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            try scratch.file("original/new.txt")
        } else {
            gate.failures[a] = .permission
            // Simulate the platform access gate rejecting a cached read, with an authoritative permission error delivered later.
            model.validateLocalSnapshot = { _, _, complete in
                complete(false); return LocationLoad()
            }
        }
        gate.held.insert(a)
        defer { gate.release(a) }
        model.setLocation(a)
        try #require(await eventually { gate.pending[a]?.isEmpty == false && !model.isRefreshing })
        #expect(model.rows.isEmpty && model.isLoading)
        gate.release(a); try await settled(model, at: a)
        if change == "permission" {
            #expect(model.rows.isEmpty && model.loadError == LocationLoadError.permission.message)
            #expect(model.localSnapshotRowsForTesting == 0)
        } else {
            #expect(model.rows.map(\.item.name) == ["new.txt"])
        }
    }

    @Test func onePreviousSlotAndKeyCountLimitBoundRetainedPayloads() async throws {
        configure()
        let scratch = try Scratch("local-back-bound")
        let a = try scratch.folder("a"), b = try scratch.folder("b"), c = try scratch.folder("c")
        try scratch.file("a/one"); try scratch.file("a/two"); try scratch.file("b/one")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload(); try await settled(model, at: a)
        model.setLocation(b); try await settled(model, at: b)
        #expect(model.localSnapshotRowsForTesting == 2)
        model.setLocation(c); try await settled(model, at: c)
        #expect(model.localSnapshotRowsForTesting == 1)
        // A source may retain many identities even when few rows are visible; those must obey the bound too.
        gate.extraKeys = Dictionary(
            uniqueKeysWithValues: (0...DirectoryModel.maximumLocalSnapshotRows).map {
                (a.appendingPathComponent("unused-\($0)"), "unused-\($0)")
            })
        model.setLocation(a); try await settled(model, at: a)
        model.setLocation(b); try await settled(model, at: b)
        #expect(model.localSnapshotRowsForTesting == 0)
    }

    @Test func pendingDisplayMetadataDoesNotDisableAnOtherwiseValidBackSnapshot() async throws {
        configure()
        let scratch = try Scratch("local-back-display-metadata")
        let a = try scratch.folder("a"), b = try scratch.folder("b")
        try scratch.file("a/item.txt")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload(); try await settled(model, at: a)
        let item = try #require(model.rows.first?.item)
        _ = model.shownCloud(for: item); _ = model.shownTags(for: item)
        // Real drawing schedules this lazy work before the next main turn/navigation action.
        model.setLocation(b); try await settled(model, at: b)
        #expect(model.localSnapshotRowsForTesting == 1)
        gate.held.insert(a)
        defer { gate.release(a) }
        model.setLocation(a)
        try #require(await eventually { !model.isLoading && model.isRefreshing })
        #expect(model.rows.map(\.item.name) == ["item.txt"])
        gate.release(a); try await settled(model, at: a)
    }

    @Test(arguments: [false, true])
    func onlyIncomingTransfersIntoTheCachedFolderBlockReuse(sameFolder: Bool) async throws {
        configure()
        let scratch = try Scratch("local-back-unrelated-transfer")
        let a = try scratch.folder("a"), b = try scratch.folder("b"), c = try scratch.folder("c")
        try scratch.file("a/item.txt")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload(); try await settled(model, at: a)
        model.setLocation(b); try await settled(model, at: b)
        let target = sameFolder ? a : c
        let activity = Activity(kind: .copy, sources: [], destination: target, job: nil)
        activity.state = .running
        activity.incomingItem = FileItem(url: target.appendingPathComponent("incoming"), name: "incoming", isDirectory: false)
        FileOperationsController.shared.activities.append(activity)
        NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        gate.held.insert(a)
        defer {
            gate.release(a)
            FileOperationsController.shared.activities.removeAll { $0 === activity }
        }
        model.setLocation(a)
        if sameFolder {
            try #require(await eventually { gate.pending[a]?.isEmpty == false })
            #expect(model.rows.isEmpty && model.isLoading)
        } else {
            try #require(await eventually { !model.isLoading && model.isRefreshing })
            #expect(model.rows.map(\.item.name) == ["item.txt"])
        }
        gate.release(a); try await settled(model, at: a)
    }

    @Test(arguments: ["search", "tree", "tags", "columns", "edit", "listing", "incoming"])
    func provisionalOrNonflatListingsCannotSeedThePreviousSlot(state: String) async throws {
        configure()
        let scratch = try Scratch("local-back-ineligible")
        let a = try scratch.folder("a"), b = try scratch.folder("b")
        let file = try scratch.file("a/item.txt")
        try scratch.folder("a/folder")
        try scratch.file("a/folder/child.txt")
        let model = DirectoryModel(location: a, prefetchFolders: false), gate = Gate()
        gate.install(on: model); model.reload(); try await settled(model, at: a)
        var activity: Activity?
        defer {
            if let activity { FileOperationsController.shared.activities.removeAll { $0 === activity } }
        }
        switch state {
        case "search": model.searchResults = [try #require(FileItem.load(file))]
        case "tree":
            let listedFolder = try #require(model.rows.first { $0.item.isDirectory }?.item.url)
            model.setExpanded(listedFolder, true)
            try #require(await eventually { !model.isLoading && model.rows.count == 3 })
        case "tags": model.props.sortRole = .tags; try await settled(model, at: a)
        case "columns": model.props.mode = .columns
        case "edit":
            model.applyEdit(
                ListingEdit(folder: a, added: [FileItem(url: a.appendingPathComponent("optimistic"), name: "optimistic", isDirectory: false)]))
        case "listing": model.reload()
        default:
            let incoming = Activity(kind: .copy, sources: [], destination: a, job: nil)
            incoming.state = .running
            incoming.incomingItem = FileItem(url: a.appendingPathComponent("incoming"), name: "incoming", isDirectory: false)
            activity = incoming
            FileOperationsController.shared.activities.append(incoming)
            NotificationCenter.default.post(name: FileOperationsController.activityChanged, object: nil)
        }
        model.setLocation(b); try await settled(model, at: b)
        #expect(model.localSnapshotRowsForTesting == 0)
    }
}

private final class ReentrantCachedSource: LocationContentSource {
    let location: URL
    var loads = 0
    init(location: URL) { self.location = location }
    var traits: LocationTraits { LocationTraits(paintsCache: true) }
    func cached(_ folder: URL) -> [FileItem]? {
        [FileItem(url: location.appendingPathComponent("cached.txt"), name: "cached.txt", isDirectory: false)]
    }
    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        loads += 1
        return LocationLoad()
    }
}
