import AppKit
import PorpoiseCore
import PorpoiseServices
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    private(set) var windows: [MainWindowController] = []
    private var sessionSave: DispatchWorkItem?
    /// The last session wasn't reopened, because reopening it was what went wrong last time.
    private var skippedRestore = false
    private var settingsWindow: SettingsWindowController?
    private var lookObservation: NSKeyValueObservation?
    private var drewInitialWindow = false
    /// Set while a session is being reopened: still set at the next launch, reopening it crashed or hung, and that launch
    /// opens the home folder instead of trying again.
    static let restoringKey = "session.restoring"
    /// How long after its windows appear a reopened session counts as restored: its folders have listed by then.
    static let restoreSettleTime: TimeInterval = 5

    // MARK: - Launch and quit

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if PORPOISE_TEST_HOOKS
        FocusGuard.install()
        #endif
        connectServices()
        // "Show in Finder" requests from other apps, when Porpoise is the default file browser.
        SystemIntegration.installRevealHandlers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.launched()
        followLook()
        NSApp.mainMenu = buildMainMenu()
        MenuCommandRegistry.shared.start()
        NSApp.registerServicesMenuSendTypes([.fileURL], returnTypes: [])
        VideoPreview.shared.cleanUp()
        // Test hook only in test launches of test and local builds (never in normal use, never in a release).
        #if PORPOISE_TEST_HOOKS
        if Settings.isTesting { DebugBridge.shared.start() }
        #endif
        var args = Self.folderArguments()
        // Launched by Archive Utility to reveal what it unpacked: macOS doesn't say what (see RevealInference).
        if args.isEmpty, windows.isEmpty, SystemIntegration.isDefaultBrowser,
            NSAppleEventManager.shared().currentAppleEvent?.eventID == AEEventID(kAEOpenApplication),
            let item = RevealInference.launchItem(folders: RevealInference.folders(shown: savedSessionFolders))
        {
            args = [(item.deletingLastPathComponent(), item)]
        }
        // First launch: the browser window at once, with the welcome as a sheet on it (only when launched plainly).
        let welcome = args.isEmpty && windows.isEmpty && OnboardingWindowController.shouldShow
        openInitialWindows(args)
        DispatchQueue.main.async { AppAutomation.shared.start() }
        if welcome { OnboardingWindowController.show(on: windows.first?.window) }
        Updates.shared.start()
        PrivilegedHelper.migrateFromLoginItems()
        // After the windows are up, so the question has something behind it.
        if !Settings.isTesting { DispatchQueue.main.async { [weak self] in self?.offerRecovery() } }
    }

    /// Light or dark as chosen in Settings (as macOS is, by default), and the switch when either changes: what's drawn
    /// follows by itself, layers are given their new colors.
    private func followLook() {
        NSApp.appearance = Theme.appearance
        Theme.dressWindows()
        lookObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { Theme.lookChanged() }
        }
        // The accent colour (System Settings › Appearance): the native theme's selection, focus and folders follow it.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Theme.lookChanged() }
        }
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { n in
            guard n.object == nil || ["appearance", "appearancePreferences"].contains(n.object as? String ?? "") else { return }
            MainActor.assumeIsolated {
                NSApp.appearance = Theme.appearance; Theme.lookChanged()
            }
        }
    }

    private func openInitialWindows(_ args: [(folder: URL, select: URL?)]) {
        if !args.isEmpty {
            // A file argument opens its folder with the file selected (Dolphin's --select).
            newWindow(urls: args.map(\.folder))
            if let file = args.first?.select { windows.last?.view.pendingSelect = file }
        } else if !windows.isEmpty {
            // Launched to open folders or reveal files ("Show in Finder" from another app): those windows only.
        } else if Settings.shared.startup == .lastSession, restoreSession() {
            // Restored.
        } else {
            newWindow(at: Settings.shared.homeURL)
            if skippedRestore {
                windows.last?.view.messageBar.show(
                    "Porpoise quit while reopening your last windows, so it opened your home folder instead.", error: false)
            }
        }
        NSApp.activate()
    }

    /// Path arguments: folders open; files open their folder, selected (the first one). Skips "-Key value"
    /// defaults pairs and paths that don't exist.
    private static func folderArguments() -> [(folder: URL, select: URL?)] {
        var out: [(URL, URL?)] = []
        var skipNext = false
        for a in CommandLine.arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if a.hasPrefix("-") { skipNext = !a.hasPrefix("--"); continue }
            let path = (a as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let u = URL(fileURLWithPath: path).standardizedFileURL
            out.append(isDir.boolValue ? (u, nil) : (u.deletingLastPathComponent(), u))
        }
        return out
    }

    /// Reopens the windows and tabs of the last session, each one as it was before it is shown (no window first shows
    /// the home folder, or appears elsewhere, before changing); false if there was nothing to restore.
    func restoreSession() -> Bool {
        let store = Settings.store
        if store.bool(forKey: Self.restoringKey) {
            // The last launch didn't get through reopening its session: don't try the same again.
            store.removeObject(forKey: Self.restoringKey)
            skippedRestore = true
            return false
        }
        let (session, missing) = SessionState(stored: store.object(forKey: SessionState.key)).available()
        guard !session.windows.isEmpty else { return false }
        store.set(true, forKey: Self.restoringKey)
        for layout in session.windows {
            if let wc = MainWindowController(layout: layout) { show(add(wc, cascading: layout.frame == nil)) }
        }
        if let message = SessionState.missingMessage(missing) { windows.last?.view.messageBar.show(message, error: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreSettleTime) { store.removeObject(forKey: Self.restoringKey) }
        return true
    }

    /// The folders of the last session's tabs.
    private var savedSessionFolders: [URL] {
        SessionState(stored: Settings.store.object(forKey: SessionState.key)).windows.flatMap { $0.tabs.map(\.primary.url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Archive Utility revealing what it unpacked arrives as a bare reopen (see RevealInference).
        if revealUnpacked(after: NSAppleEventManager.shared().currentAppleEvent) { return false }
        // Minimized windows are brought back by AppKit; a new one only when there is none.
        if !flag && windows.isEmpty { newWindow(at: Settings.shared.homeURL) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Dolphin asks before quitting with several tabs open.
        if Settings.shared.confirmCloseTabs, windows.contains(where: { $0.tabs.count > 1 }) {
            let a = NSAlert()
            let tabs = windows.reduce(0) { $0 + $1.tabs.count }
            a.messageText = "Quit Porpoise with \(tabs) tabs open?"
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don’t ask again"
            let r = a.runModal()
            if a.suppressionButton?.state == .on { Settings.shared.confirmCloseTabs = false }
            if r != .alertFirstButtonReturn { return .terminateCancel }
        }
        // Quitting ends the Terminal panels' shells too (closing the window asks the same).
        if Settings.shared.confirmCloseTerminal,
            let w = windows.first(where: { $0.showTerminal && $0.terminal.hasRunningProgram })
        {
            let a = NSAlert()
            a.messageText = "Quit Porpoise and stop “\(w.terminal.runningProgramName)”?"
            a.informativeText = "It's still running in the Terminal panel. Quitting ends it."
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        // Copies still running stop where they are and can be resumed next time.
        let running = FileOperationsController.shared.activities.filter { $0.state.isActive || $0.state == .queued }
        if !running.isEmpty {
            let a = NSAlert()
            a.messageText =
                running.count == 1
                ? "A file operation is still running. Quit anyway?" : "\(running.count) file operations are still running. Quit anyway?"
            a.informativeText =
                "Copies and moves stop where they are; Porpoise offers to resume them next time it starts. Deleting is never resumed without asking."
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        if FileDiffWindow.confirmQuitIfNeeded({ [weak self] approved in
            if approved {
                self?.saveSession()
                if self?.finishSharingBeforeQuit({ NSApp.reply(toApplicationShouldTerminate: true) }) == true { return }
            }
            NSApp.reply(toApplicationShouldTerminate: approved)
        }) {
            return .terminateLater
        }
        saveSession()
        if finishSharingBeforeQuit({ NSApp.reply(toApplicationShouldTerminate: true) }) { return .terminateLater }
        return .terminateNow
    }

    @MainActor private func finishSharingBeforeQuit(_ completion: @escaping () -> Void) -> Bool {
        SharingCoordinator.shared.cancelAll()
        return PreparedSharingItems.cleanupBeforeQuit(completion: completion)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // AppKit can ask when a drag-image window disappears after hiding. Hidden or ordered-out browser
        // windows still belong to this session; only closing the last real browser should quit it.
        !sender.isHidden && windows.isEmpty
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.quitting()
        FileOperationsController.shared.interruptAll()
        VideoPreview.shared.cleanUp()
        RemoteFS.disconnectAll()
        AndroidTools.stopServerIfOurs()
        saveSession()
        // Quitting while a session reopens isn't a failed restore.
        Settings.store.removeObject(forKey: Self.restoringKey)
        CloudStateWriter.shared.flushAll()
    }

    // MARK: - Opening folders and revealing files

    /// Shows items selected in their folder (Finder's reveal).
    func reveal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent()
        if let w = windows.first, Settings.shared.singleWindow {
            w.addTab(url: parent)
            w.view.pendingSelect = first
            w.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(at: parent)
            windows.last?.view.pendingSelect = first
        }
        NSApp.activate()
    }

    /// Reveals what Archive Utility just unpacked when `event` is its reopen; false when it isn't.
    func revealUnpacked(after event: NSAppleEventDescriptor?) -> Bool {
        let shown = windows.flatMap { $0.tabs.map(\.primary.url) }
        guard let event, let item = RevealInference.reopenItem(event, folders: RevealInference.folders(shown: shown)) else { return false }
        reveal([item])
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Files are revealed in their folder; folders open.
        func isFolder(_ u: URL) -> Bool? {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) ? d.boolValue : nil
        }
        let files = urls.filter { isFolder($0) == false }
        if !files.isEmpty && files.count == urls.count { reveal(files); return }
        let folders = urls.map { isFolder($0) == true ? $0 : $0.deletingLastPathComponent() }
        // "Keep a single Porpoise window, opening new folders in tabs".
        if let w = windows.first, Settings.shared.singleWindow {
            for f in folders { w.addTab(url: f) }
            w.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(urls: folders)
        }
    }

    // MARK: - Windows

    func newWindow(at url: URL, split: URL? = nil) { newWindow(urls: [url], split: [split]) }

    func newWindow(urls: [URL], split: [URL?] = []) { show(add(MainWindowController(urls: urls, split: split))) }

    /// Keeps `wc` among the browser windows, not shown yet.
    private func add(_ wc: MainWindowController, cascading: Bool = true) -> MainWindowController {
        // Cascade from the previous window, like document windows.
        if cascading, let last = windows.last?.window {
            wc.window?.setFrame(last.frame.offsetBy(dx: 24, dy: -24), display: false)
        }
        windows.append(wc)
        return wc
    }

    private func show(_ wc: MainWindowController) {
        #if PORPOISE_TEST_HOOKS
        // What each window showed when it first appeared (the bridge's `session` reports it).
        firstShown.append(wc.captureLayout())
        #endif
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        guard !drewInitialWindow else { return }
        drewInitialWindow = true
        // Present the browser before next-turn Git discovery or background decoding of optional custom tools.
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.contentView?.displayIfNeeded()
        CATransaction.flush()
        DispatchQueue.main.async {
            Settings.shared.prepareCustomToolsAfterFirstWindow()
            SharingPreparation.sweepStaleCopiesAfterLaunch()
            RemoteOpener.sweepStaleCopiesAfterLaunch()
        }
    }

    #if PORPOISE_TEST_HOOKS
    private(set) var firstShown: [WindowLayout] = []
    #endif

    func windowClosed(_ wc: MainWindowController) {
        windows.removeAll { $0 === wc }
    }

    func saveSession() {
        sessionSave?.cancel()
        sessionSave = nil
        let state = SessionState(windows: windows.map { $0.captureLayout() })
        if !state.windows.isEmpty { Settings.store.set(state.stored, forKey: SessionState.key) }
    }

    /// How soon after a change the session is saved: a crash or a forced quit loses at most this much.
    static let sessionSaveDelay: TimeInterval = 2

    /// Saves the session shortly after a change (navigation, tabs, the split, panels, scrolling, the window's frame):
    /// once for a burst of changes, never put off by more of them.
    func sessionChanged() {
        guard sessionSave == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sessionSaveDelay, execute: w)
    }

    /// Cmd+W in windows without tabs (Settings, Properties…) closes the window, as on any Mac.
    @objc func closeCurrentTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    /// Every permission, its state and its switch: Settings › System.
    @objc func showPermissions(_ sender: Any?) { showSettings(page: "Advanced") }
    @objc func checkForUpdates(_ sender: Any?) { Updates.shared.checkForUpdates(sender) }
    @objc func supportPorpoise(_ sender: Any?) { if let u = URL(string: AppInfo.sponsorPage) { NSWorkspace.shared.open(u) } }

    @objc func showActivity(_ sender: Any?) { ActivityWindowController.shared.show() }

    /// Jobs left unfinished last time (a quit, a crash, a power cut): offers to resume each, after checking that
    /// its items haven't changed. Deleting is never resumed without asking.
    func offerRecovery() {
        let c = FileOperationsController.shared
        for plan in c.recoveryPlans() {
            let a = NSAlert()
            a.messageText = plan.isEmpty ? "\(plan.kind.verb) was interrupted last time" : plan.summary
            var info = plan.notes
            if plan.isDestructive && !plan.isEmpty {
                a.alertStyle = .warning
                info.append(
                    "Resuming deletes the remaining items: \(plan.sources.prefix(3).map(\.lastPathComponent).joined(separator: ", "))\(plan.sources.count > 3 ? "…" : "")."
                )
            } else if !plan.isEmpty {
                info.append("Items already finished are not done again; a large file continues from where it stopped.")
            }
            a.informativeText = info.joined(separator: "\n")
            if plan.isEmpty {
                a.addButton(withTitle: "OK")
                a.runModal()
                c.discard(plan)
                continue
            }
            a.addButton(withTitle: plan.isDestructive ? "Delete Remaining" : "Resume")
            a.addButton(withTitle: "Discard")
            a.addButton(withTitle: "Later")
            if plan.isDestructive { a.buttons[0].hasDestructiveAction = true }
            switch a.runModal() {
            case .alertFirstButtonReturn: c.recover(plan, window: nil)
            case .alertSecondButtonReturn: c.discard(plan)
            default: break  // asked again next launch
            }
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        NSApp.activate()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// Settings, on the page with this title.
    func showSettings(page: String) {
        showSettings(nil)
        guard let tabs = settingsWindow?.window?.contentViewController as? NSTabViewController,
            let i = tabs.tabViewItems.firstIndex(where: { $0.label == page })
        else { return }
        tabs.selectedTabViewItemIndex = i
    }

    @objc func configureShortcuts(_ sender: Any?) { showSettings(page: "Shortcuts") }

    @objc func exportDiagnostics(_ sender: Any?) { DiagnosticsExportWindowController.show() }

    @objc func showLocationCapabilities(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let location = ProviderLocation(rawValue: key) else { return }
        let alert = NSAlert()
        alert.messageText = location.title + " Capabilities"
        alert.informativeText = location.help
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func showHelp(_ sender: Any?) {
        if let u = URL(string: AppInfo.homepage) { NSWorkspace.shared.open(u) }
    }
}
