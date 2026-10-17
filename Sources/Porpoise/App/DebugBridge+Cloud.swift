import AppKit
import PorpoiseCore
import PorpoiseServices

extension DebugBridge {
    /// Files a test instance "opened in their app" (`cloud nolaunch`).
    nonisolated(unsafe) static var openedFiles: [String] = []

    /// cloud <command>: drives the demo cloud backend (PORPOISE_CLOUD_DEMO) and the Connect sheet.
    /// - `add <id>|<email>|<name>|<shared drives>|<used bytes>|<total bytes>`: an account, as if connected earlier
    /// - `finish <same fields>` / `cancel`: ends the browser sign-in in progress; `fail <message>`
    /// - `status <id> ok|offline|signin`, `avatar <id> <image file>`
    /// - `sheet` opens the Connect sheet; `tile <provider or server kind>` picks a tile on it; `page <file>` writes its page
    /// - `settingsremove` / `settingsselect <id>`: Settings › Accounts' − button / account list
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
        case "settingsremove": AccountsSettingsPage.current?.removeAccount()
        case "settingsselect": AccountsSettingsPage.current?.select(rest)
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
                let timer = Timer(timeInterval: ms / 1000, repeats: false) { _ in Self.capture([window.windowNumber], to: f[0]) }
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
            guard f.count == 2, let e = DriveEditing.shared.entries.first(where: { $0.name == f[0] }) else { return }
            try? Data(f[1].utf8).write(to: e.localURL)
        case "edits":
            // edits <file>: what Activity lists about files being edited, and the files opened.
            let lines =
                DriveEditing.shared.entries.map { "\($0.name) | \($0.mark) | \($0.title) | \($0.detail)" }
                + DebugBridge.openedFiles.map { "opened \($0)" }
            try? lines.joined(separator: "\n").write(toFile: rest, atomically: true, encoding: .utf8)
        case "editresolve":
            // editresolve <name>|keep|copy|open|replace|send: Activity's buttons for a file being edited.
            let f = rest.components(separatedBy: "|")
            guard f.count == 2, let e = DriveEditing.shared.entries.first(where: { $0.name == f[0] }) else { return }
            switch f[1] {
            case "keep", "copy": DriveEditing.shared.keepBoth(e.id)
            case "open": DriveEditing.shared.openBoth(e.id)
            case "replace": DriveEditing.shared.replaceWithMine(e.id)
            default: DriveEditing.shared.save(e.id)
            }
        case "copyonly":
            // copyonly on|off: as on real Drive until conditional saves are verified (saves wait for Save as a Copy).
            DriveEditing.shared.savesVersions = rest == "on" ? { _ in false } : { $0.canSaveEdits }
        case "poll": CloudAccounts.shared.checkForChanges()
        case "activity": ActivityWindowController.shared.show()
        case "select":
            // select <name>: the row with that name (cloud items are ids in their URLs).
            if let v = AppDelegate.shared.windows.first?.view, let row = v.model.rows.first(where: { $0.item.name == rest }) {
                v.list.select(row.item.url)
            }
        default: break
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
            let ids = a.count > 3 && a[3] == "all" ? Self.ownWindowIDs() : ([window.attachedSheet].compactMap { $0 } + [window]).map(\.windowNumber)
            Self.capture(ids, to: a[0])
        }
    }

    /// Every on-screen window of this process, front to back: open menus, popovers and tooltips too.
    static func ownWindowIDs() -> [Int] {
        let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }.compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    /// Window-server images of these windows only (whatever covers them on screen), composited front to back.
    static func capture(_ windowIDs: [Int], to path: String) {
        var ids: [UnsafeRawPointer?] = windowIDs.map { UnsafeRawPointer(bitPattern: $0) }
        typealias Fn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let count = ids.count
        let list = ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, count, nil) }
        // kCGWindowImageBoundsIgnoreFraming
        guard let list, let image = fn(.null, list, 1)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
            Self.capture(Self.ownWindowIDs(), to: f[1])
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: at, in: list) }
    }
}
