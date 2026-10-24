// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices

extension DebugBridge {
    /// The demo cloud backend, the Connect sheet and cloud captures.
    static let cloudCommands: [String: Command] = ["cloud": DebugBridge.cloudDemo(_:)]

    /// Files a test instance "opened in their app" (`cloud nolaunch`).
    nonisolated(unsafe) static var openedFiles: [String] = []

    /// cloud <command>: drives the demo cloud backend (PORPOISE_CLOUD_DEMO) and the Connect sheet.
    /// - `add <id>|<email>|<name>|<shared drives>|<used bytes>|<total bytes>`: an account, as if connected earlier
    /// - `finish <same fields>` / `cancel`: ends the browser sign-in in progress; `fail <message>`
    /// - `status <id> ok|offline|signin`, `avatar <id> <image file>`
    /// - `sheet` opens the Connect sheet; `tile <provider or server kind>` picks a tile on it; `page <file>` writes its page
    /// - `settingsremove` / `settingsselect <id | server:<uuid>>`: the Accounts & Servers window's − button / its list
    /// - `info <url>|<owner>|<email>|<access>|<count>|<link role>|<modified by>|<shared by>|<web link>|<kind>`
    func cloudDemo(_ arg: String) {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        let demo = CloudAccounts.shared.backend as? DemoCloudBackend
        func account(_ s: String) -> CloudAccount? {
            let f = s.components(separatedBy: "|")
            guard f.count >= 3 else { return nil }
            return CloudAccount(
                id: f[0], email: f[1], displayName: f[2], quotaUsed: f.count > 4 ? Int64(f[4]) : nil, quotaTotal: f.count > 5 ? Int64(f[5]) : nil,
                sharedDriveCount: f.count > 3 ? Int(f[3]) ?? 0 : 0)
        }
        switch parts.first {
        case "add":
            guard let a = account(rest), let demo else { return }
            _ = demo.connect(.googleDrive, openBrowser: { _ in }, done: { _ in })
            demo.finishSignIn(a)
        case "finish": demo?.finishSignIn(account(rest))
        case "cancel": demo?.finishSignIn(nil)
        case "fail": demo?.failSignIn(rest)
        case "status":
            let f = rest.split(separator: " ").map(String.init)
            guard f.count == 2 else { return }
            demo?.setStatus(f[0], f[1] == "offline" ? .offline : f[1] == "signin" ? .signInNeeded : .ok)
        case "avatar":
            let f = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let data = FileManager.default.contents(atPath: f[1]) else { return }
            demo?.avatars[f[0]] = data
        case "sheet":
            ConnectSheet.run(window: AppDelegate.shared.windows.first?.window) { url in AppDelegate.shared.windows.first?.view.setURL(url) }
        case "tile":
            guard let sheet = ConnectSheet.current?.window?.contentView else { return }
            func find(_ v: NSView) -> ConnectTile? {
                if let t = v as? ConnectTile, t.identifier?.rawValue == "tile-" + rest { return t }
                return v.subviews.lazy.compactMap(find).first
            }
            find(sheet)?.onClick?()
        case "page":
            try? "\(ConnectSheet.current.map { "\($0.page)" } ?? "none")".write(toFile: rest, atomically: true, encoding: .utf8)
        case "info":
            let f = rest.components(separatedBy: "|")
            guard f.count >= 10, let u = URL(string: f[0]) else { return }
            demo?.infos[u] = CloudItemInfo(
                ownerName: f[1], ownerEmail: f[2], access: CloudItemInfo.Access(rawValue: f[3]), sharedWithCount: Int(f[4]),
                sharedWithNames: [], anyoneWithLink: f[5].isEmpty ? nil : f[5], modifiedBy: f[6], sharedBy: f[7].isEmpty ? nil : f[7],
                webLink: URL(string: f[8]), isWebDocument: f[9].hasPrefix("Google"), kind: f[9])
        case "shot": shot(rest)
        case "settingsremove": AccountsServersWindow.current?.removeSelected(nil)
        case "settingsselect":
            let server = rest.hasPrefix("server:") ? UUID(uuidString: String(rest.dropFirst(7))) : nil
            AccountsServersWindow.showFromFront(selecting: server.map { .server($0) } ?? .account(rest))
        case "rename":
            // rename <name>|<new name>: through the inline rename's path.
            let f = rest.components(separatedBy: "|")
            guard f.count == 2, let w = AppDelegate.shared.windows.first, let row = w.view.model.rows.first(where: { $0.item.name == f[0] }) else {
                return
            }
            w.rename(row.item, to: f[1], in: w.view)
        case "itemrect":
            // itemrect <name>|<file>: the item's icon centre in window points from the top-left (for real-event drivers).
            let f = rest.components(separatedBy: "|")
            guard f.count == 2, let w = AppDelegate.shared.windows.first, let win = w.window,
                let i = w.view.model.rows.firstIndex(where: { $0.item.name == f[0] })
            else { return }
            let r = w.view.list.convert(w.view.list.iconRect(i), to: nil)
            try? "\(Int(r.midX)) \(Int(win.frame.height - r.midY))".write(toFile: f[1], atomically: true, encoding: .utf8)
        case "barbutton":
            // barbutton <file>: the message bar's action button centre, in window points from the top-left.
            guard let w = AppDelegate.shared.windows.first, let win = w.window, let f = w.view.messageBar.actionFrame else { return }
            let r = w.view.messageBar.convert(f, to: nil)
            try? "\(Int(r.midX)) \(Int(win.frame.height - r.midY))".write(toFile: rest, atomically: true, encoding: .utf8)
        case "menushot": menuShot(rest)
        case "glideshot":
            // glideshot <png>|<ms>: the main window <ms> after the next Drive change starts gliding in (no activation).
            let f = rest.components(separatedBy: "|")
            guard Settings.isTesting, f.count == 2, let ms = Double(f[1]), let w = AppDelegate.shared.windows.first, let window = w.window else {
                return
            }
            let previous = w.view.model.onRemoteUpdate
            w.view.model.onRemoteUpdate = { apply in
                previous?(apply)
                w.view.model.onRemoteUpdate = previous
                let timer = Timer(timeInterval: ms / 1000, repeats: false) { _ in WindowCapture.write([window.windowNumber], to: f[0]) }
                RunLoop.main.add(timer, forMode: .common)
            }
        case "barclick":
            // barclick: the message bar's action button (Undo, Allow Changes…), as a click does.
            AppDelegate.shared.windows.first?.view.messageBar.performAction()
        case "type":
            // type <text>: replaces the text being edited (the New Folder name, an inline rename), as typing does.
            let window = NSApp.windows.first { $0.isVisible && $0.isSheet } ?? AppDelegate.shared.windows.first?.window
            if let editor = window?.firstResponder as? NSTextView {
                editor.selectAll(nil)
                editor.insertText(rest, replacementRange: editor.selectedRange())
            }
        case "newfolder":
            // newfolder <name>: what the New Folder dialog's Create does.
            AppDelegate.shared.windows.first?.createCloudFolder(named: rest)
        case "split":
            // split [<folder id>]: opens the split view on that Drive folder of the first account (none: the same folder).
            guard let w = AppDelegate.shared.windows.first else { return }
            let account = MainActor.assumeIsolated { DriveAccountStore.shared.accounts.first }
            let url = rest.isEmpty ? nil : account.map { DriveLocation(accountID: $0.id, collection: .folder(rest)).url }
            w.tab.openSplit(url: url)
            w.tab.secondary?.delegate = w
        case "unsplit": AppDelegate.shared.windows.first?.tab.closeSplit(closeActive: true)
        case "nolaunch":
            // nolaunch: files "opened in their app" are only recorded (no other app starts in a test instance).
            RemoteOpener.openFile = { DebugBridge.openedFiles.append($0.path) }
        case "open":
            // open <name>: the row with that name, as a double-click opens it.
            if let w = AppDelegate.shared.windows.first, let row = w.view.model.rows.first(where: { $0.item.name == rest }) {
                RemoteOpener.open(row.item)
            }
        case "editwrite":
            // editwrite <name>|<text>: another app saves the file being edited.
            let f = rest.components(separatedBy: "|")
            guard f.count == 2, let e = CloudEditing.shared.entries.first(where: { $0.name == f[0] }) else { return }
            try? Data(f[1].utf8).write(to: e.localURL)
        case "edits":
            // edits <file>: what Activity lists about files being edited, and the files opened.
            let lines =
                CloudEditing.shared.entries.map { "\($0.name) | \($0.mark) | \($0.title) | \($0.detail)" }
                + DebugBridge.openedFiles.map { "opened \($0)" }
            try? lines.joined(separator: "\n").write(toFile: rest, atomically: true, encoding: .utf8)
        case "editresolve":
            // editresolve <name>|keep|copy|open|replace|send: Activity's buttons for a file being edited.
            let f = rest.components(separatedBy: "|")
            guard f.count == 2, let e = CloudEditing.shared.entries.first(where: { $0.name == f[0] }) else { return }
            switch f[1] {
            case "keep", "copy": CloudEditing.shared.keepBoth(e.id)
            case "open": CloudEditing.shared.openBoth(e.id)
            case "replace": CloudEditing.shared.replaceWithMine(e.id)
            default: CloudEditing.shared.save(e.id)
            }
        case "driveprobe":
            // driveprobe <report.json>: the live save-back probe on the first Drive account (outcomes only, no IDs).
            guard let account = CloudAccounts.shared.accounts.first(where: { $0.provider == .googleDrive }),
                let id = UUID(uuidString: account.id), let client = CloudEditCoordinator.shared.client(id)
            else { try? Data("{\"error\":\"no Drive account\"}".utf8).write(to: URL(fileURLWithPath: rest)); return }
            Task {
                let report = await DriveSaveBackProbe(client: client).run()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try? encoder.encode(report).write(to: URL(fileURLWithPath: rest))
            }
        case "download": AppDelegate.shared.windows.first?.cloudDownload(nil)
        case "evict": AppDelegate.shared.windows.first?.cloudEvict(nil)
        case "accounts":
            let accounts = CloudAccounts.shared
            let rows = accounts.accounts.map { account in
                [
                    "id": account.id, "provider": account.provider.rawValue, "email": account.email,
                    "root": accounts.url(account.id, root: .myDrive)?.absoluteString ?? "",
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: rest))
            }
        case "poll": CloudAccounts.shared.checkForChanges()
        case "activity": ActivityWindowController.shared.show()
        case "select":
            // select <name>: the row with that name (cloud items are ids in their URLs).
            if let v = AppDelegate.shared.windows.first?.view, let row = v.model.rows.first(where: { $0.item.name == rest }) {
                v.list.select(row.item.url)
            }
        case "offline": offlineDemo(rest)
        default: break
        }
    }

    /// `cloud offline …` drives the demo offline service (PORPOISE_OFFLINE_DEMO):
    /// - `<item name>|<kept|inherited:<folder>|downloaded|cloudonly|downloading:<0…1>|uploading:<0…1>|error:<why>>`
    /// - `plan <bytes>|<items>|<available>|<fits 1/0>`: what the next Download counts
    /// - `deny <item name>|<reason>`, `refuse <item name>|<message>`, `usage <account id>|<kept>|<recent>`
    private func offlineDemo(_ arg: String) {
        guard let demo = CloudOfflineHub.service as? DemoOfflineService else { return }
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let f = (words.count > 1 ? words[1] : arg).components(separatedBy: "|")
        func url(_ name: String) -> URL? {
            AppDelegate.shared.windows.first?.view.model.rows.first { $0.item.name == name }?.item.url
        }
        switch words.first {
        case "plan" where f.count == 4:
            demo.nextPlan = CloudKeepPlan(
                bytes: Int64(f[0]) ?? 0, items: Int(f[1]) ?? 0, available: Int64(f[2]) ?? 0, fits: f[3] == "1")
        case "deny" where f.count == 2: if let u = url(f[0]) { demo.denials[u] = f[1] }
        case "refuse" where f.count == 2: if let u = url(f[0]) { demo.refusals[u] = f[1] }
        case "usage" where f.count == 3: demo.usages[f[0]] = CloudOfflineUsage(kept: Int64(f[1]) ?? 0, recent: Int64(f[2]) ?? 0)
        default:
            let g = arg.components(separatedBy: "|")
            guard g.count == 2, let u = url(g[0]) else { return }
            if let row = AppDelegate.shared.windows.first?.view.model.rows.first(where: { $0.item.url == u }), row.item.isBrowsableFolder {
                demo.folders.insert(u)
            }
            demo.set(u, g[1])
        }
    }

    /// `cloud shot <png>|<light|dark>|<main|settings|title prefix>[|all]`: brings the instance to the front and captures that
    /// window together with its sheet, through the window server (materials and all). Take the capture lock first.
    private func shot(_ arg: String) {
        guard Settings.isTesting else { return }
        let a = arg.components(separatedBy: "|")
        guard a.count >= 3 else { return }
        Settings.store.set(a[1], forKey: "appearance")
        NotificationCenter.default.post(name: Settings.changed, object: "appearance")
        let target: NSWindow?
        switch a[2] {
        case "main": target = AppDelegate.shared.windows.first?.window
        case "settings": target = NSApp.windows.first { $0.isVisible && $0.windowController is SettingsWindowController }
        default: target = NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(a[2]) }
        }
        guard let window = target else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let ids =
                a.count > 3 && a[3] == "all"
                ? WindowCapture.ownWindowIDs() : ([window.attachedSheet].compactMap { $0 } + [window]).map(\.windowNumber)
            WindowCapture.write(ids, to: a[0])
        }
    }

    /// `cloud menushot <item name or empty>|<png>`: the item's context menu (the background's when empty), opened at
    /// the item as a right-click would, captured while it is open, then closed.
    private func menuShot(_ arg: String) {
        let f = arg.components(separatedBy: "|")
        guard Settings.isTesting, f.count == 2, let w = AppDelegate.shared.windows.first else { return }
        let list = w.view.list
        let row = w.view.model.rows.firstIndex { $0.item.name == f[0] }
        if let row { list.select(w.view.model.rows[row].item.url) } else { w.view.model.selection = [] }
        let menu = w.contextMenu(for: row.map { w.view.model.rows[$0].item }, in: w.view)
        let at = row.map { CGPoint(x: list.iconRect($0).midX, y: list.iconRect($0).midY) } ?? CGPoint(x: list.bounds.midX, y: 300)
        // The menu runs its own tracking loop: the capture is a timer in the common modes, which that loop serves.
        let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
            WindowCapture.write(WindowCapture.ownWindowIDs(), to: f[1])
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: at, in: list) }
    }
}

#endif
