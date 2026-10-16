import AppKit
import PorpoiseCore
import PorpoiseServices
import UserNotifications

/// All visible state lives on main; scans, planning, baseline and definition persistence run elsewhere.
final class SyncCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SyncCoordinator()
    static let changed = Notification.Name("PorpoiseSavedSyncsChanged")
    static let activityChanged = Notification.Name("PorpoiseSyncActivityChanged")
    enum Status { case idle, planning, syncing, conflicts(Int), failed(String), paused, missing, review(Int) }
    private(set) var pairs: [SavedSync] = []
    private(set) var statuses: [UUID: Status] = [:]
    private(set) var activities: [UUID: Activity] = [:]
    private var watchers: [UUID: SyncWatcher] = [:]
    private var preparing: Set<UUID> = []
    private var dirty: Set<UUID> = []
    private var lastActivities: [UUID: Activity] = [:]
    private var runs: [UUID: SyncPreview] = [:]
    private var runPaths: [UUID: [String: String]] = [:]
    private var recoveryJournals: [UUID: PlanJournal] = [:]
    private var notices: [UUID: String] = [:]
    private var observers: [NSObjectProtocol] = []
    let store: SavedSyncStore
    let stateStore: SyncStateStore
    private var loaded = false
    private var loadFailed = false
    private var pendingWrites: [(Bool) -> Void] = []
    private var saveTask: Task<Void, Never>?

    private override init() {
        let base =
            Settings.isTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-sync-review-\(getpid())")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise")
        store = SavedSyncStore(file: base.appendingPathComponent("syncs.json"))
        stateStore = SyncStateStore(folder: base.appendingPathComponent("SyncState"))
        super.init()
        observers.append(
            NotificationCenter.default.addObserver(forName: FileOperationsController.activityChanged, object: nil, queue: .main) {
                [weak self] _ in self?.updateActivities()
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: Notification.Name("PorpoiseCompareSyncRequested"), object: nil, queue: .main) {
                notification in
                guard let window = notification.object as? NSWindow,
                    let left = notification.userInfo?["left"] as? URL, let right = notification.userInfo?["right"] as? URL
                else { return }
                (window.windowController as? MainWindowController)?.openSyncForComparison(
                    leftRoot: left, rightRoot: right, options: notification.userInfo?["options"] as? SyncCompareOptions ?? .init(),
                    comparison: notification.userInfo?["comparison"] as? SyncComparison,
                    overrides: notification.userInfo?["overrides"] as? [String: SyncOverride] ?? [:],
                    keepAutomatically: notification.userInfo?["automatic"] as? Bool ?? false)
            })
        if !Settings.isTesting { UNUserNotificationCenter.current().delegate = self; configureNotificationActions() }
        Task { @MainActor in
            do {
                let stored = try await store.load()
                let localIDs = Set(pairs.map(\.id))
                pairs = stored.filter { !localIDs.contains($0.id) } + pairs
                loaded = true
                let waiting = pendingWrites; pendingWrites = []
                if !waiting.isEmpty { persist { success in waiting.forEach { $0(success) } } }
                await offerRecovery()
                for pair in stored where pairs.first(where: { $0.id == pair.id }) == pair { installWatcher(pair) }
                changed()
            } catch {
                loadFailed = true
                let waiting = pendingWrites; pendingWrites = []; waiting.forEach { $0(false) }
                showError(error.localizedDescription, window: nil)
            }
        }
    }
    func pair(left: URL, right: URL) -> SavedSync? { pairs.first { $0.left == left && $0.right == right } }
    func activity(left: URL, right: URL) -> Activity? {
        activities.first { id, _ in runs[id].map { $0.pair.left == left && $0.pair.right == right } ?? false }?.value
    }
    func save(_ pair: SavedSync, replacing previousID: UUID? = nil) {
        if let previousID, previousID != pair.id {
            watchers.removeValue(forKey: previousID)?.stop(); pairs.removeAll { $0.id == previousID }
            Task { try? await stateStore.remove(pairID: previousID) }
        }
        var previous = pairs.first { $0.id == pair.id }; previous?.lastSynced = pair.lastSynced
        if let index = pairs.firstIndex(where: { $0.id == pair.id }) { pairs[index] = pair } else { pairs.append(pair) }
        let watcherChanged = previous != pair
        if watcherChanged { watchers.removeValue(forKey: pair.id)?.stop() }
        persist { [weak self] succeeded in
            guard let self, succeeded, watcherChanged, self.pairs.first(where: { $0.id == pair.id }) == pair else { return }
            self.installWatcher(pair)
        }
        changed()
    }
    private func persist(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !loadFailed else { completion(false); return }
        guard loaded else { pendingWrites.append(completion); return }
        let snapshot = pairs, previous = saveTask, store = store
        // Preserve edit ordering even if several controls save in the same run-loop turn.
        saveTask = Task { @MainActor [weak self] in
            await previous?.value
            do { try await store.save(snapshot); completion(true) } catch {
                self?.showError(error.localizedDescription, window: nil)
                completion(false)
            }
        }
    }
    func remove(_ pair: SavedSync, window: NSWindow?, onRemoved: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = "Remove the “\(pair.name)” sync?"
        alert.informativeText = "Your files aren't touched; Porpoise stops syncing this pair and forgets its history."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        func finish(_ answer: NSApplication.ModalResponse) {
            guard answer == .alertFirstButtonReturn else { return }
            if let activity = self.activities[pair.id] { FileOperationsController.shared.cancel(activity) }
            self.dirty.remove(pair.id)
            Task { try? await self.stateStore.remove(pairID: pair.id) }
            self.watchers.removeValue(forKey: pair.id)?.stop()
            self.pairs.removeAll { $0.id == pair.id }
            self.statuses.removeValue(forKey: pair.id)
            self.persist(); self.changed(); onRemoved?()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
    func setPaused(_ pair: SavedSync, paused: Bool) {
        var next = pair; next.paused = paused
        if let activity = activities[pair.id], !activity.state.isEnded {
            if paused { FileOperationsController.shared.pause(activity) } else { FileOperationsController.shared.resume(activity) }
        }
        save(next)
        statuses[pair.id] = paused ? .paused : (activities[pair.id] != nil ? .syncing : .idle)
        if !paused { requestScan(pair.id) }
        changed()
    }
    private func installWatcher(_ pair: SavedSync) {
        watchers.removeValue(forKey: pair.id)?.stop()
        guard pair.automatic else { return }
        if pair.paused {
            if case .review = statuses[pair.id] {} else { statuses[pair.id] = .paused }
        }
        Task { @MainActor [weak self] in
            let watcher = await Task.detached(priority: .utility) {
                let watcher = SyncWatcher(roots: [pair.left, pair.right]) {
                    DispatchQueue.main.async { SyncCoordinator.shared.requestScan(pair.id) }
                }
                watcher.setPaused(pair.paused)
                return watcher
            }.value
            guard let self, self.pairs.first(where: { $0.id == pair.id }) == pair else { watcher.stop(); return }
            self.watchers[pair.id] = watcher
            if !pair.paused { self.requestScan(pair.id) }
        }
    }
    func requestScan(_ id: UUID) {
        guard let pair = pairs.first(where: { $0.id == id }), pair.automatic, !pair.paused, recoveryJournals[id] == nil else { return }
        guard !preparing.contains(id), activities[id] == nil else { dirty.insert(id); return }
        // Serialize all pair runs, including overlapping roots: an event never authorizes racing two executors.
        guard preparing.isEmpty, activities.isEmpty, finishing.isEmpty else { dirty.insert(id); return }
        preparing.insert(id); statuses[id] = .planning; changed()
        Task { @MainActor in
            do {
                let previous = try await stateStore.load(pairID: id, leftRoot: pair.left, rightRoot: pair.right)
                let preview = try await Task.detached(priority: .utility) { try SyncPreparation.preview(pair, previous: previous) }.value
                preparing.remove(id)
                guard pairs.first(where: { $0.id == id }) == pair, !pair.paused else { drain(); return }
                if preview.requiresDeletionReview {
                    var paused = pair; paused.paused = true; save(paused)
                    statuses[id] = .review(preview.deletionCount)
                    notify(
                        pair, key: "deletions:\(preview.deletionCount)", title: "Sync paused",
                        body: "\(preview.deletionCount) items would be moved to the Trash in \(pair.right.lastPathComponent).")
                    changed(); drain(); return
                }
                if preview.skippedConflicts > 0 { attention(preview) }
                if preview.executable.steps.isEmpty {
                    if previous == nil, preview.skippedConflicts == 0 {
                        try await stateStore.save(
                            .init(left: preview.left, right: preview.right), pairID: id, leftRoot: pair.left, rightRoot: pair.right)
                    }
                    idle(preview); drain()
                } else {
                    run(preview, window: nil, background: true)
                }
            } catch {
                preparing.remove(id)
                // Missing/offline roots are quiet; failures with an available pair need a person.
                let ns = error as NSError
                if ns.code == NSFileNoSuchFileError || ns.code == 2 || ns.domain == NSURLErrorDomain
                    || error.localizedDescription.lowercased().contains("connection")
                {
                    statuses[id] = .missing
                } else {
                    statuses[id] = .failed(error.localizedDescription)
                    notify(pair, key: "failure:\(error.localizedDescription)", title: "Couldn't sync \(pair.name)", body: error.localizedDescription)
                }
                changed(); drain()
            }
        }
    }
    func run(
        _ preview: SyncPreview, recovering: PlanJournal? = nil, window: NSWindow?, background: Bool = false,
        onStarted: ((Activity) -> Void)? = nil, onFinished: (() -> Void)? = nil
    ) {
        var preview = preview
        var pair = preview.pair
        if case .review = statuses[pair.id] { pair.paused = false; preview.pair = pair }
        if recovering == nil, let journal = recoveryJournals[pair.id] { presentRecovery(journal, pair: pair, window: window); return }
        guard preparing.isEmpty, activities.isEmpty, finishing.isEmpty else {
            if background {
                dirty.insert(pair.id)
            } else {
                showError("Another sync is running. Wait for it to finish, then try again.", window: window)
            }
            return
        }
        save(pair)
        preparing.insert(pair.id); statuses[pair.id] = .planning; changed()
        Task { @MainActor in
            do {
                let journal = try await Task.detached(priority: .userInitiated) {
                    if let recovering { return recovering }
                    return try SyncJobs.journal(preview.executable, title: "Sync \(pair.description)", leftRoot: pair.left, rightRoot: pair.right)
                }.value
                FileOperationsController.shared.enqueuePlanAsync(
                    journal, window: window, shouldEnqueue: { self.pairs.contains { $0.id == pair.id } },
                    execute: { step, context in
                        try context.checkCancellation()
                        if Settings.isTesting, let delay = ProcessInfo.processInfo.environment["PORPOISE_SYNC_STEP_DELAY"].flatMap(Double.init),
                            delay > 0
                        {
                            Thread.sleep(forTimeInterval: min(1, delay))
                        }
                        try SyncJobs.execute(step, context: context)
                    }
                ) { result in
                    self.preparing.remove(pair.id)
                    switch result {
                    case .failure(let error):
                        if self.pairs.contains(where: { $0.id == pair.id }) {
                            self.statuses[pair.id] = .failed(error.localizedDescription); self.showError(error.localizedDescription, window: window)
                        }
                        self.changed(); self.drain()
                    case .success(let activity):
                        activity.showsCurrentStepTitle = false
                        let copied = preview.executable.steps.filter { $0.action == .copy || $0.action == .replace }.count
                        let trashed = preview.executable.steps.filter { $0.action == .trash }.count
                        activity.completionSummary =
                            "Synced · \(copied) copied" + (trashed > 0 ? " · \(trashed) moved to the Trash" : "") + " · just now"
                        self.activities[pair.id] = activity; self.runs[pair.id] = preview
                        self.runPaths[pair.id] = Dictionary(uniqueKeysWithValues: preview.plan.steps.map { ($0.id, $0.path) })
                        self.statuses[pair.id] = .syncing
                        self.completions[pair.id] = onFinished
                        onStarted?(activity)
                        self.changed(); self.updateActivities()
                    }
                }
            } catch {
                preparing.remove(pair.id); statuses[pair.id] = .failed(error.localizedDescription);
                showError(error.localizedDescription, window: window); changed()
            }
        }
    }
    func recordReviewedEmpty(_ preview: SyncPreview) {
        save(preview.pair)
        if preview.skippedConflicts > 0 { attention(preview); return }
        guard !preview.hasSkippedItems else { return }
        Task { @MainActor in
            do {
                try await stateStore.save(
                    .init(left: preview.left, right: preview.right), pairID: preview.pair.id,
                    leftRoot: preview.pair.left, rightRoot: preview.pair.right)
                if let index = pairs.firstIndex(where: { $0.id == preview.pair.id }), pairs[index].lastSynced == nil {
                    pairs[index].lastSynced = Date(); persist()
                }
                statuses[preview.pair.id] = .idle; changed()
            } catch { showError(error.localizedDescription, window: nil) }
        }
    }
    private var completions: [UUID: () -> Void] = [:]
    private func updateActivities() {
        for (id, activity) in activities {
            if activity.state == .paused { statuses[id] = .paused } else if activity.state == .running { statuses[id] = .syncing }
            NotificationCenter.default.post(
                name: Self.activityChanged, object: activity.originWindow,
                userInfo: [
                    "activity": activity, "left": runs[id]!.pair.left, "right": runs[id]!.pair.right,
                    "completedPaths": (activity.planProgress?.completedStepIDs ?? []).compactMap { stepID in self.runPaths[id]?[stepID] },
                ])
            guard activity.state.isEnded, let preview = runs.removeValue(forKey: id) else { continue }
            lastActivities[id] = activity
            activities.removeValue(forKey: id)
            runPaths.removeValue(forKey: id)
            let completion = completions.removeValue(forKey: id)
            guard pairs.contains(where: { $0.id == id }) else { completion?(); changed(); drain(); continue }
            if activity.state == .completed && activity.errors.isEmpty {
                // Baselines advance only when no conflict or explicit exclusion from this run was left behind.
                finishing.insert(id)
                Task { @MainActor in
                    defer { finishing.remove(id); completion?(); changed(); drain() }
                    do {
                        if preview.skippedConflicts == 0 && !preview.hasSkippedItems {
                            let pair = preview.pair
                            let scan = try await Task.detached(priority: .utility) {
                                try SyncScanner.compare(pair.left, pair.right, options: pair.options)
                            }.value
                            try await stateStore.save(
                                .init(left: scan.left, right: scan.right), pairID: id, leftRoot: pair.left, rightRoot: pair.right)
                        }
                        var pair = preview.pair; pair.lastSynced = Date()
                        if let index = pairs.firstIndex(where: { $0.id == id }) { pairs[index].lastSynced = pair.lastSynced; persist() }
                        idle(preview)
                    } catch {
                        statuses[id] = .failed(error.localizedDescription);
                        showError(error.localizedDescription, window: activity.originWindow as? NSWindow)
                    }
                }
            } else {
                statuses[id] =
                    activity.state == .cancelled || activity.state == .interrupted ? .paused : .failed(activity.errors.first ?? "Sync stopped.")
                if !activity.errors.isEmpty {
                    if let owner = activity.originWindow as? NSWindow {
                        FileOperationsController.shared.ui?.showTransferErrors(activity, window: owner)
                    }
                    notify(preview.pair, key: "failure:\(activity.errors)", title: "Couldn't sync \(preview.pair.name)", body: activity.errors.first!)
                }
                if preview.pair.automatic, activity.state == .cancelled || activity.state == .interrupted {
                    if var pair = pairs.first(where: { $0.id == id }) { pair.paused = true; save(pair) }
                }
                completion?(); changed(); drain()
            }
        }
    }
    private var finishing: Set<UUID> = []
    private func drain() {
        guard preparing.isEmpty, activities.isEmpty, finishing.isEmpty else { return }
        while let next = dirty.first {
            dirty.remove(next)
            if let pair = pairs.first(where: { $0.id == next }), pair.automatic, !pair.paused, recoveryJournals[next] == nil {
                requestScan(next); return
            }
        }
    }
    private func idle(_ preview: SyncPreview) {
        if preview.skippedConflicts > 0 {
            attention(preview)
        } else {
            statuses[preview.pair.id] = .idle; notices.removeValue(forKey: preview.pair.id)
        }
        changed()
    }
    private func attention(_ preview: SyncPreview) {
        statuses[preview.pair.id] = .conflicts(preview.skippedConflicts)
        notify(
            preview.pair, key: "conflicts:\(preview.plan.conflicts.map(\.path).joined(separator: "|"))",
            title: "\(preview.pair.description) needs you", body: "\(preview.skippedConflicts) files changed on both sides.")
    }
    private func notify(_ pair: SavedSync, key: String, title: String, body: String) {
        guard pair.automatic, !Settings.isTesting, notices[pair.id] != key else { return }
        notices[pair.id] = key
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        content.threadIdentifier = pair.id.uuidString
        content.categoryIdentifier = key.hasPrefix("failure:") ? "PORPOISE_SYNC_SHOW" : "PORPOISE_SYNC_REVIEW"
        content.userInfo = ["pair": pair.id.uuidString]
        UNUserNotificationCenter.current().add(.init(identifier: "sync-\(pair.id)", content: content, trigger: nil))
    }
    private func configureNotificationActions() {
        let review = UNNotificationAction(identifier: "review", title: "Review", options: [.foreground])
        let show = UNNotificationAction(identifier: "show", title: "Show", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            .init(identifier: "PORPOISE_SYNC_REVIEW", actions: [review], intentIdentifiers: []),
            .init(identifier: "PORPOISE_SYNC_SHOW", actions: [show], intentIdentifiers: []),
        ])
    }
    func enableNotifications() {
        guard !Settings.isTesting else { return }
        configureNotificationActions()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let value = response.notification.request.content.userInfo["pair"] as? String, let id = UUID(uuidString: value) {
            DispatchQueue.main.async {
                if response.actionIdentifier == "show", let activity = self.lastActivities[id], !activity.errors.isEmpty {
                    FileOperationsController.shared.ui?.showTransferErrors(activity, window: NSApp.keyWindow)
                } else {
                    self.review(id, window: NSApp.keyWindow)
                }
            }
        }
        completionHandler()
    }
    func review(_ id: UUID, window: NSWindow?, editing: Bool = false) {
        guard let pair = pairs.first(where: { $0.id == id }) else { return }
        if let journal = recoveryJournals[id] { presentRecovery(journal, pair: pair, window: window); return }
        let owner = window ?? AppDelegate.shared.windows.first?.window
        guard let owner else { return }
        SyncSheetController(pair: pair, owner: owner, editing: editing).present()
    }
    private func offerRecovery() async {
        let journalStore = FileOperationsController.shared.planJournals
        let recovered = await Task.detached(priority: .utility) {
            ((try? journalStore.all()) ?? []).compactMap { journal -> (PlanJournal, URL, URL)? in
                guard let value = try? SyncJobs.restore(journal) else { return nil }
                return (journal, value.leftRoot, value.rightRoot)
            }
        }.value
        for (journal, left, right) in recovered {
            var pair = pair(left: left, right: right) ?? SavedSync(left: left, right: right)
            if !pairs.contains(where: { $0.id == pair.id }) { pair.visibleInSidebar = true; pairs.append(pair) }
            recoveryJournals[pair.id] = journal; statuses[pair.id] = .paused
        }
        if !Settings.isTesting, let first = recoveryJournals.first, let pair = pairs.first(where: { $0.id == first.key }) {
            presentRecovery(first.value, pair: pair, window: AppDelegate.shared.windows.first?.window)
        }
    }
    private func presentRecovery(_ journal: PlanJournal, pair: SavedSync, window: NSWindow?) {
        guard let window = window ?? AppDelegate.shared.windows.first?.window else { return }
        let alert = NSAlert(); alert.messageText = "“\(pair.description)” was interrupted"
        alert.informativeText =
            "Resume the reviewed plan? Finished steps are kept. Remaining deletions go to the Trash. Changed files are checked before anything is replaced."
        alert.addButton(withTitle: "Resume"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                self.recoveryJournals.removeValue(forKey: pair.id)
                Task { @MainActor in
                    do {
                        let preview = try await Task.detached(priority: .userInitiated) {
                            let restored = try SyncJobs.restore(journal)
                            var preview = try SyncPreparation.preview(pair)
                            preview.plan = restored.plan
                            preview.hasSkippedItems = true  // Conservatively retain the baseline after crash recovery.
                            return preview
                        }.value
                        self.run(preview, recovering: journal, window: window)
                    } catch {
                        self.recoveryJournals[pair.id] = journal
                        self.showError(error.localizedDescription, window: window)
                    }
                }
            } else if response == .alertSecondButtonReturn {
                Task { @MainActor in
                    let store = FileOperationsController.shared.planJournals
                    do {
                        try await Task.detached(priority: .utility) { try store.remove(journal.id) }.value
                        self.recoveryJournals.removeValue(forKey: pair.id); self.requestScan(pair.id); self.changed()
                    } catch { self.showError(error.localizedDescription, window: window) }
                }
            }
        }
    }
    private func changed() {
        PlacesModel.shared.setSyncEntries(pairs.filter(\.visibleInSidebar))
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    func create(window: NSWindow?, left: URL?) {
        guard let window, let left else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Choose Backup Folder"; panel.message = "Choose the other folder to sync with “\(left.lastPathComponent)”."
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let right = panel.url else { return }
            SyncSheetController(pair: SavedSync(left: left, right: right), owner: window).present()
        }
    }
    /// Representative rendering states only, for isolated design captures. Does not execute or persist pairs.
    func installReviewSidebarStates(left: URL, right: URL) {
        guard Settings.isTesting, activities.isEmpty, preparing.isEmpty else { return }
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll(); dirty.removeAll()
        let names = ["Projects", "Photos", "Website", "Documents", "Work", "Archive"]
        pairs = names.map { name in
            var pair = SavedSync(name: name, left: left, right: right)
            pair.automatic = true; pair.lastSynced = Date().addingTimeInterval(-120); return pair
        }
        let values: [Status] = [.idle, .syncing, .conflicts(2), .failed("Permission denied"), .paused, .missing]
        for (index, pair) in pairs.enumerated() { statuses[pair.id] = values[index] }
        changed()
    }
    func pair(for url: URL) -> SavedSync? { pairs.first { $0.id.uuidString.caseInsensitiveCompare(url.host ?? "") == .orderedSame } }
    func open(_ pair: SavedSync, window: NSWindow?, newTab: Bool = false) {
        NotificationCenter.default.post(
            name: Notification.Name("PorpoiseCompareOpenRequested"), object: window,
            userInfo: ["left": pair.left, "right": pair.right, "options": pair.options, "newTab": newTab])
    }
    func tooltip(_ pair: SavedSync) -> String {
        let suffix: String
        switch statuses[pair.id] ?? .idle {
        case .missing: suffix = "\(pair.right.lastPathComponent) isn't available. Porpoise will sync when it's back."
        case .failed(let reason): suffix = reason
        case .conflicts(let count): suffix = "\(count) conflicts need review"
        case .review(let count): suffix = "Sync paused: \(count) items would be moved to the Trash."
        default: suffix = pair.paused ? "paused" : pair.automatic ? "kept in sync" : "saved sync"
        }
        return pair.description + " · " + suffix
    }
    func showError(_ text: String, window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = "Couldn't sync"; alert.informativeText = text; alert.addButton(withTitle: "OK")
        if let window = window ?? AppDelegate.shared.windows.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            NSLog("Porpoise Sync: %@", text)
        }
    }
}
