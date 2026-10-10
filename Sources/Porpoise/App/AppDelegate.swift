import AppKit
import PorpoiseCore
import PorpoiseServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    private(set) var windows: [MainWindowController] = []
    private var settingsWindow: SettingsWindowController?
    /// UserDefaults key of the saved windows/tabs: [[["url": …, "split": …, "mode": …]]].
    private static let sessionKey = "session"

    // MARK: - Launch and quit

    func applicationWillFinishLaunching(_ notification: Notification) {
        connectServices()
        // "Show in Finder" requests from other apps, when Porpoise is the default file browser.
        SystemIntegration.installRevealHandlers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = buildMainMenu()
        NSApp.registerServicesMenuSendTypes([.fileURL], returnTypes: [])
        VideoPreview.shared.cleanUp()
        // Test hook only in test launches (never in normal use).
        if Settings.isTesting { DebugBridge.shared.start() }
        let args = Self.folderArguments()
        // First launch: the onboarding assistant comes first; the browser window opens when it's done.
        if args.isEmpty, windows.isEmpty, OnboardingWindowController.shouldShow {
            OnboardingWindowController.show { [weak self] in self?.openInitialWindows(args) }
        } else {
            openInitialWindows(args)
        }
        Updates.shared.start()
        PrivilegedHelper.migrateFromLoginItems()
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

    /// Reopens the windows and tabs of the last session; false if there was nothing to restore.
    private func restoreSession() -> Bool {
        guard let session = Settings.store.array(forKey: Self.sessionKey) as? [[[String: String]]] else { return false }
        for w in session {
            // Tab and split URLs stay paired when a vanished folder is dropped.
            let tabs = w.compactMap { t -> (url: URL, split: URL?)? in
                guard let u = t["url"].flatMap(URL.init(string:)),
                      !u.isFileURL || FileManager.default.fileExists(atPath: u.path) else { return nil }
                return (u, t["split"].flatMap(URL.init(string:)))
            }
            if !tabs.isEmpty { newWindow(urls: tabs.map(\.url), split: tabs.map(\.split)) }
        }
        return !windows.isEmpty
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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
           let w = windows.first(where: { $0.showTerminal && $0.terminal.hasRunningProgram }) {
            let a = NSAlert()
            a.messageText = "The program “\(w.terminal.runningProgramName)” is still running in the Terminal panel. Are you sure you want to quit?"
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            a.window.appearance = NSAppearance(named: .darkAqua)
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        saveSession()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        VideoPreview.shared.cleanUp()
        RemoteFS.disconnectAll()
        AndroidTools.stopServerIfOurs()
        saveSession()
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

    func newWindow(urls: [URL], split: [URL?] = []) {
        let wc = MainWindowController(urls: urls, split: split)
        windows.append(wc)
        // Cascade from the previous window, like document windows.
        if let last = windows.dropLast().last?.window {
            wc.window?.setFrame(last.frame.offsetBy(dx: 24, dy: -24), display: false)
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    func windowClosed(_ wc: MainWindowController) {
        windows.removeAll { $0 === wc }
    }

    func saveSession() {
        let state = windows.map(\.sessionState)
        if !state.isEmpty { Settings.store.set(state, forKey: Self.sessionKey) }
    }

    /// Cmd+W in windows without tabs (Settings, Properties…) closes the window, as on any Mac.
    @objc func closeCurrentTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    @objc func showPermissions(_ sender: Any?) { OnboardingWindowController.show(at: OnboardingWindowController.firstMissing) }
    @objc func checkForUpdates(_ sender: Any?) { Updates.shared.checkForUpdates(sender) }
    @objc func supportPorpoise(_ sender: Any?) { if let u = URL(string: AppInfo.sponsorPage) { NSWorkspace.shared.open(u) } }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        NSApp.activate()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func configureShortcuts(_ sender: Any?) {
        // macOS manages keyboard shortcuts for app menus centrally.
        if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") { NSWorkspace.shared.open(u) }
    }

    @objc func showHelp(_ sender: Any?) {
        if let u = URL(string: AppInfo.homepage) { NSWorkspace.shared.open(u) }
    }
}
