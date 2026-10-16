import AppKit
import PorpoiseServices

extension DebugBridge {
    /// cloud <command>: drives the demo cloud backend (PORPOISE_CLOUD_DEMO) and the Connect sheet.
    /// - `add <id>|<email>|<name>|<shared drives>|<used bytes>|<total bytes>`: an account, as if connected earlier
    /// - `finish <same fields>` / `cancel`: ends the browser sign-in in progress; `fail <message>`
    /// - `status <id> ok|offline|signin`, `avatar <id> <image file>`
    /// - `sheet` opens the Connect sheet; `tile <provider or server kind>` picks a tile on it; `page <file>` writes its page
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
        default: break
        }
    }

    /// `cloud shot <png>|<light|dark>|<main|settings|title prefix>`: brings the instance to the front and captures that
    /// window together with its sheet, through the window server (materials and all). Take the capture lock first.
    private func shot(_ arg: String) {
        guard Settings.isTesting else { return }
        let a = arg.components(separatedBy: "|")
        guard a.count == 3 else { return }
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
            var ids: [UnsafeRawPointer?] = ([window.attachedSheet].compactMap { $0 } + [window])
                .compactMap { UnsafeRawPointer(bitPattern: $0.windowNumber) }
            typealias Fn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return }
            let fn = unsafeBitCast(sym, to: Fn.self)
            let count = ids.count
            let list = ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, count, nil) }
            // kCGWindowImageBoundsIgnoreFraming
            guard let list, let image = fn(.null, list, 1)?.takeRetainedValue() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[0]))
        }
    }
}
