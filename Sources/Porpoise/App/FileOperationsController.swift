import AppKit
import PorpoiseCore

/// App-wide file operations: clipboard (cut/copy/paste), job progress, conflict dialog, undo/redo,
/// Dolphin's drop menu. Mirrors KIO's job tracker + FileUndoManager.
final class FileOperationsController {
    static let shared = FileOperationsController()
    static let cutChanged = Notification.Name("PorpoiseCutChanged")
    static let undoChanged = Notification.Name("PorpoiseUndoChanged")
    /// Posted after an operation with the folders it touched (KDirNotify equivalent); views reload at once.
    static let foldersChanged = Notification.Name("PorpoiseFoldersChanged")

    /// Posts `foldersChanged` for each URL and its parent folder.
    static func notifyChanged(_ urls: [URL]) {
        let dirs = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path } + urls.map { $0.standardizedFileURL.path })
        NotificationCenter.default.post(name: foldersChanged, object: nil, userInfo: ["paths": dirs])
    }

    private var undoStack: [UndoRecord] = []
    private var redoStack: [UndoRecord] = []
    private var cutChangeCount = -1
    private(set) var cutURLs: Set<URL> = []
    let jobsPanel = JobsPanel()

    private static var trashFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    // MARK: Clipboard

    /// The system clipboard, shared with Finder. Test instances use a private one, so automated tests
    /// never replace what the user copied.
    static let pasteboard: NSPasteboard = Settings.isTesting
        ? NSPasteboard(name: NSPasteboard.Name("app.porpoise.Porpoise.test-clipboard." + (ProcessInfo.processInfo.environment["PORPOISE_BRIDGE"] ?? "test")))
        : .general

    func copy(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        let pb = Self.pasteboard
        pb.clearContents()
        // One file URL per item, as Finder writes them, so Finder (and other apps) can paste; plus the
        // locations as text for text fields and terminals.
        pb.writeObjects(urls as [NSURL])
        pb.setString(urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n"), forType: .string)
        cutChangeCount = cut ? pb.changeCount : -1
        cutURLs = cut ? Set(urls) : []
        NotificationCenter.default.post(name: Self.cutChanged, object: nil)
    }

    /// Files on the clipboard (from Porpoise, Finder or any other app), and items of remote locations
    /// Porpoise copied (sftp://, ftp://, adb://). Web links and other URLs are not files to paste.
    var clipboardURLs: [URL] {
        let urls = (Self.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        return urls.filter { $0.isFileURL || RemoteFS.isRemote($0) }
    }

    var clipboardIsCut: Bool { Self.pasteboard.changeCount == cutChangeCount }

    /// "Paste", "Paste 3 Files", "Paste One Folder" — Dolphin's dynamic label.
    var pasteTitle: String {
        let urls = clipboardURLs
        if urls.isEmpty { return "Paste" }
        let dirs = urls.filter {
            $0.isFileURL ? (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true : $0.hasDirectoryPath
        }.count
        if urls.count == 1 { return dirs == 1 ? "Paste One Folder" : "Paste One File" }
        if dirs == urls.count { return "Paste \(urls.count) Folders" }
        if dirs == 0 { return "Paste \(urls.count) Files" }
        return "Paste \(urls.count) Items"
    }

    func paste(into folder: URL, window: NSWindow?, done: (([URL]) -> Void)? = nil) {
        let urls = clipboardURLs
        guard !urls.isEmpty else { return }
        let cut = clipboardIsCut
        run(cut ? .move : .copy, urls, to: folder, window: window) { [weak self] results in
            if cut {
                self?.cutChangeCount = -1
                self?.cutURLs = []
                Self.pasteboard.clearContents()
                NotificationCenter.default.post(name: Self.cutChanged, object: nil)
            }
            done?(results)
        }
    }

    // MARK: Jobs

    /// `sound` plays once the job has done something (Finder's trash sounds).
    func run(_ kind: FileOperationKind, _ urls: [URL], to folder: URL? = nil, window: NSWindow?, sound: FinderSound? = nil,
             done: (([URL]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        if urls.contains(where: { !$0.isFileURL }) || (folder.map { !$0.isFileURL } ?? false) {
            runRemote(kind, urls, to: folder, window: window, done: done)
            return
        }
        let job = FileJob(kind: kind, sources: urls, destinationFolder: folder)
        let row = jobsPanel.add(job)
        job.onProgress = { p in DispatchQueue.main.async { row.update(p) } }
        job.resolveConflict = { [weak self] info in
            var answer = ConflictAnswer(.cancel)
            DispatchQueue.main.sync { answer = self?.askConflict(info, kind: kind, window: window) ?? ConflictAnswer(.cancel) }
            return answer
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var record: UndoRecord?
            var fatal: Error?
            do { record = try job.run() } catch { fatal = error }
            DispatchQueue.main.async {
                Self.notifyChanged(urls + (folder.map { [$0] } ?? []) + job.results)
                self.jobsPanel.finish(row)
                if let r = record { self.pushUndo(r); self.recordTrash(r) }
                // One sound per action: now, or once the items needing authentication are done too.
                let deniedLeft = !job.denied.isEmpty && !job.isCancelled
                if record != nil && !deniedLeft { sound?.play() }
                let errs = job.errors + (fatal.map { [($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription] } ?? [])
                if !errs.isEmpty && !job.isCancelled { self.showErrors(errs, window: window) }
                if !job.untrashable.isEmpty && !job.isCancelled { self.offerDelete(job.untrashable, window: window) }
                if !job.denied.isEmpty && !job.isCancelled {
                    self.retryDenied(kind, job.denied, targets: job.deniedTargets, to: folder, window: window) { more in
                        if record != nil || !more.isEmpty { sound?.play() }
                        done?(job.results + more)
                    }
                } else {
                    done?(job.results)
                }
            }
        }
    }

    /// Moves items to the Trash; `sound` is Finder's: "move to trash", or "drag to trash" for the Dock's Trash.
    func trash(_ urls: [URL], window: NSWindow?, sound: FinderSound = .moveToTrash) {
        guard !urls.isEmpty else { return }
        let remote = urls.filter { !$0.isFileURL }
        if !remote.isEmpty {
            // Remote locations have no Trash (Dolphin deletes permanently there, after asking). Local items
            // in the same selection still go to the Trash.
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = remote.count == 1 ? "Permanently delete “\(remote[0].lastPathComponent)”?" : "Permanently delete these \(remote.count) items?"
            a.informativeText = "Remote locations don't have a Trash. This action cannot be undone."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            guard runAlert(a, window: window) == .alertFirstButtonReturn else { return }
            runRemote(.delete, remote, to: nil, window: window, done: nil)
        }
        // Apple's own apps live on the read-only system volume: macOS doesn't allow removing them.
        let builtIn = urls.filter { $0.isFileURL && AppLibrary.isBuiltIn($0) }
        if !builtIn.isEmpty {
            let a = NSAlert()
            a.messageText = builtIn.count == 1
                ? "“\(AppLibrary.displayName(builtIn[0]))” is part of macOS and can't be moved to the Trash."
                : "\(builtIn.count) of these items are part of macOS and can't be moved to the Trash."
            a.informativeText = "macOS keeps its built-in apps on a protected system volume."
            _ = runAlert(a, window: window)
        }
        let local = urls.filter { $0.isFileURL && !AppLibrary.isBuiltIn($0) }
        guard !local.isEmpty else { return }
        if Settings.shared.confirmTrash {
            let a = NSAlert()
            a.messageText = local.count == 1 ? "Do you really want to move “\(local[0].lastPathComponent)” to the trash?"
                : "Do you really want to move these \(local.count) items to the trash?"
            a.addButton(withTitle: "Move to Trash")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Do not ask again"
            guard runAlert(a, window: window) == .alertFirstButtonReturn else { return }
            if a.suppressionButton?.state == .on { Settings.shared.confirmTrash = false }
        }
        run(.trash, local, window: window, sound: sound)
    }

    /// Finder: items on a volume without a Trash can only be deleted right away, after asking.
    private func offerDelete(_ urls: [URL], window: NSWindow?) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = urls.count == 1
            ? "“\(urls[0].lastPathComponent)” can't be moved to the Trash. Do you want to delete it immediately?"
            : "These \(urls.count) items can't be moved to the Trash. Do you want to delete them immediately?"
        a.informativeText = "Their volume has no Trash. This action cannot be undone."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        guard runAlert(a, window: window) == .alertFirstButtonReturn else { return }
        run(.delete, urls, window: window)
    }

    func delete(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty else { return }
        if Settings.shared.confirmDelete {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = urls.count == 1 ? "Do you really want to delete “\(urls[0].lastPathComponent)”?"
                : "Do you really want to delete these \(urls.count) items?"
            a.informativeText = "This action cannot be undone."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Do not ask again"
            guard runAlert(a, window: window) == .alertFirstButtonReturn else { return }
            if a.suppressionButton?.state == .on { Settings.shared.confirmDelete = false }
        }
        run(.delete, urls, window: window)
    }

    /// Empties the Trash of the home folder and of every mounted volume, as Finder does.
    func emptyTrash(window: NSWindow?) {
        let fm = FileManager.default
        let items = Self.allTrashFolders().flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        if items.isEmpty { return }
        if Settings.shared.confirmEmptyTrash {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Do you really want to empty the Trash? All items will be deleted."
            a.informativeText = "This action cannot be undone."
            a.addButton(withTitle: "Empty Trash")
            a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Do not ask again"
            guard runAlert(a, window: window) == .alertFirstButtonReturn else { return }
            if a.suppressionButton?.state == .on { Settings.shared.confirmEmptyTrash = false }
        }
        FinderSound.emptyTrash.play()   // Finder plays it as emptying starts
        run(.delete, items, window: window)
    }

    /// ~/.Trash plus the per-user Trash folders of other mounted volumes (/Volumes/X/.Trashes/<uid>).
    private static func allTrashFolders() -> [URL] {
        let fm = FileManager.default
        var folders = [trashFolder]
        for v in fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] where v.path != "/" {
            let t = v.appendingPathComponent(".Trashes/\(getuid())")
            if FileJob.itemExists(at: t), !folders.contains(t) { folders.append(t) }
        }
        return folders
    }

    // MARK: Permission denied → unlock your own items, or authenticate (as Finder does)

    /// `targets` maps denied copy/move/link sources to where the job meant to put them (the job may have
    /// renamed them, and items from a merge go into subfolders); missing ones go to `folder`.
    /// `done` gets the items that ended up done: new copies/moves/links, or where trashed and deleted items were.
    private func retryDenied(_ kind: FileOperationKind, _ urls: [URL], targets: [URL: URL], to folder: URL?,
                             window: NSWindow?, done: @escaping ([URL]) -> Void) {
        var remaining = urls
        var unlocked: [URL] = []
        if kind == .delete || kind == .trash {
            let (left, trashed) = unlockOwnItems(urls, kind: kind)
            remaining = left
            unlocked = trashed.map(\.1) + (kind == .delete ? urls.filter { !left.contains($0) } : [])
            if !trashed.isEmpty {
                let r = UndoRecord.trashed(trashed.map { (original: $0.0, inTrash: $0.1) })
                pushUndo(r)
                recordTrash(r)
            }
        }
        guard !remaining.isEmpty else { Self.notifyChanged(urls); done(unlocked); return }

        var cmds: [[String]] = []
        var results: [URL] = []
        var skipped: [String] = []
        var trashNames = Set<String>()   // two denied items named alike must not land on the same name
        var trashPairs: [(original: URL, inTrash: URL)] = []
        for u in remaining {
            switch kind {
            case .delete:
                cmds.append(["/usr/bin/chflags", "-R", "nouchg,noschg", u.path])
                cmds.append(["/bin/rm", "-rf", "--", u.path])
            case .trash:
                let dst = Self.freeTrashURL(for: u, reserving: &trashNames)
                trashPairs.append((original: u, inTrash: dst))
                cmds.append(["/bin/mv", "--", u.path, dst.path])
            case .move, .copy, .link:
                guard let dst = targets[u] ?? folder?.appendingPathComponent(u.lastPathComponent) else { continue }
                // mv/cp/ln would put the item *inside* an existing folder instead of replacing it.
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dst.path, isDirectory: &isDir), isDir.boolValue || kind == .link {
                    skipped.append("“\(dst.lastPathComponent)” already exists in “\(dst.deletingLastPathComponent().lastPathComponent)”.")
                    continue
                }
                let tool = kind == .move ? ["/bin/mv"] : (kind == .copy ? ["/bin/cp", "-pR"] : ["/bin/ln", "-s"])
                cmds.append(tool + ["--", u.path, dst.path])
                results.append(dst)
            }
        }
        if !skipped.isEmpty { showErrors(skipped, window: window) }
        let ok = Self.authorize(verb: Self.permissionVerb(kind), items: remaining, commands: cmds, window: window)
        // Remember where they came from, so "Restore" can put them back.
        if ok && !trashPairs.isEmpty {
            recordTrash(.trashed(trashPairs))
            // Yours from now on: emptying the Trash won't need the helper for them.
            PrivilegedHelper.takeOwnership(of: trashPairs.map(\.inTrash.path))
        }
        Self.notifyChanged(remaining + (folder.map { [$0] } ?? []) + results + trashPairs.map(\.inTrash))
        done(unlocked + (ok ? results + trashPairs.map(\.inTrash) + (kind == .delete ? remaining : []) : []))
    }

    /// Locked or read-only items you own: clears the lock and write protection, then tries again.
    /// Returns the items that still fail, and where trashed ones went.
    private func unlockOwnItems(_ urls: [URL], kind: FileOperationKind) -> (remaining: [URL], trashed: [(URL, URL)]) {
        let fm = FileManager.default
        var trashed: [(URL, URL)] = []
        let remaining = urls.filter { u in
            let owner = (try? fm.attributesOfItem(atPath: u.path)[.ownerAccountID] as? NSNumber)?.uint32Value
            guard owner == getuid() else { return true }
            let recursive = kind == .delete ? ["-R"] : []
            _ = try? Shell.run("/usr/bin/chflags", recursive + ["nouchg", u.path])
            _ = try? Shell.run("/bin/chmod", recursive + ["u+w", u.path])
            do {
                if kind == .delete {
                    try fm.removeItem(at: u)
                } else {
                    var out: NSURL?
                    try fm.trashItem(at: u, resultingItemURL: &out)
                    if let o = out as URL? { trashed.append((u, o)) }
                }
                return false
            } catch {
                return true
            }
        }
        return (remaining, trashed)
    }

    private static func permissionVerb(_ kind: FileOperationKind) -> String {
        switch kind {
        case .delete: return "delete"
        case .trash: return "move to the Trash"
        case .move: return "move"
        case .copy: return "copy"
        case .link: return "link"
        }
    }

    /// An unused name in ~/.Trash ("name.ext", "name 2.ext", "name 3.ext"…), also avoiding `reserved`,
    /// which collects the names handed out so far.
    private static func freeTrashURL(for url: URL, reserving reserved: inout Set<String>) -> URL {
        var dst = trashFolder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        while reserved.contains(dst.lastPathComponent) || FileJob.itemExists(at: dst) {
            dst = trashFolder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        reserved.insert(dst.lastPathComponent)
        return dst
    }

    /// Finder's "authenticate to continue": explains, then runs the commands as administrator through the
    /// standard macOS prompt. Returns true if they ran successfully. Each command is a program and its arguments
    /// (see PorpoiseHelperInfo.allowedTools); with Porpoise's helper switched on they run without asking.
    @discardableResult
    static func authorize(verb: String, items: [URL], commands: [[String]], window: NSWindow?) -> Bool {
        guard !commands.isEmpty else { return false }
        // Porpoise's helper (set up in onboarding) does it at once, without asking.
        if !Settings.isTesting {
            // Porpoise's helper does it at once, without asking. Not installed yet (or a new version of it): it's
            // installed once, with macOS's administrator dialog, and the action continues.
            guard PrivilegedHelper.ensureOn(window: window) else { return false }
            // Clearing lock flags is best effort, as in Finder; the operation itself reports what went wrong.
            switch PrivilegedHelper.run(commands, bestEffort: ["/usr/bin/chflags"]) {
            case .done: return true
            case .failed(let err): showAuthorizationError(err); return false
            case .unavailable(let why):
                showAuthorizationError("Porpoise's helper isn't responding (\(why)). If it's switched off under System Settings › General › Login Items & Extensions, switch it on and try again.")
                return false
            }
        }
        let a = NSAlert()
        a.messageText = items.count == 1 ? "Porpoise needs your permission to \(verb) “\(items[0].lastPathComponent)”."
            : "Porpoise needs your permission to \(verb) \(items.count) items."
        a.informativeText = (items.count > 1 ? items.prefix(6).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ") + "\n\n" : "")
            + "These items belong to another user or the system. Authenticate as an administrator to continue, "
            + "or turn on Porpoise's helper in Porpoise › Permissions… to never be asked again."
        a.addButton(withTitle: "Authenticate")
        a.addButton(withTitle: "Cancel")
        a.window.appearance = NSAppearance(named: .darkAqua)
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        let q = RemoteParsing.quote
        let shell = commands.map { c in
            let line = c.map(q).joined(separator: " ")
            return c.first == "/usr/bin/chflags" ? "( \(line) 2>/dev/null; true )" : "( \(line) )"
        }.joined(separator: " && ")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \(Escaping.appleScriptString(shell)) with administrator privileges")?.executeAndReturnError(&err)
        guard let err else { return true }
        if (err[NSAppleScript.errorNumber] as? Int) == userCancelledError { return false }
        showAuthorizationError(err[NSAppleScript.errorMessage] as? String ?? "The operation failed.")
        return false
    }

    private static func showAuthorizationError(_ msg: String) {
        let e = NSAlert()
        e.alertStyle = .warning
        e.messageText = msg.contains("Operation not permitted")
            ? "macOS blocked this. Allow Porpoise under System Settings › Privacy & Security › App Management (for apps) or Full Disk Access, then try again."
            : msg
        e.window.appearance = NSAppearance(named: .darkAqua)
        e.runModal()
    }

    /// AppleScript's "User canceled." error number.
    private static let userCancelledError = -128

    private func runAlert(_ a: NSAlert, window: NSWindow?) -> NSApplication.ModalResponse {
        a.window.appearance = NSAppearance(named: .darkAqua)
        return a.runModal()
    }

    private func showErrors(_ errs: [String], window: NSWindow?) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = errs.count == 1 ? errs[0] : "\(errs.count) items could not be processed."
        if errs.count > 1 { a.informativeText = errs.prefix(8).joined(separator: "\n") }
        a.window.appearance = NSAppearance(named: .darkAqua)
        // A job can outlive its window; its errors then show on their own instead of on a closed window.
        if let w = window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    private func askConflict(_ info: ConflictInfo, kind: FileOperationKind, window: NSWindow?) -> ConflictAnswer {
        ConflictDialog(info: info, kind: kind).run()
    }

    // MARK: Remote jobs (SSH, FTP, Android)

    /// Copies/moves between local folders and providers. There is no conflict dialog here, so an item
    /// whose name already exists at the destination is reported and left alone, never overwritten.
    private func runRemote(_ kind: FileOperationKind, _ urls: [URL], to folder: URL?, window: NSWindow?, done: (([URL]) -> Void)?) {
        let job = FileJob(kind: kind, sources: urls, destinationFolder: folder)   // used for the progress row only
        let row = jobsPanel.add(job)
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            var results: [URL] = []
            var existing: Set<String>?
            for (i, src) in urls.enumerated() {
                if job.isCancelled { break }
                DispatchQueue.main.async {
                    row.update(JobProgress(kind: kind, totalBytes: 0, doneBytes: 0, totalItems: urls.count, doneItems: i,
                                           currentName: src.lastPathComponent, destination: folder))
                }
                do {
                    switch kind {
                    case .delete, .trash:
                        if let p = RemoteFS.provider(for: src) { try p.delete([src]) } else { try FileManager.default.removeItem(at: src) }
                    case .link:
                        throw RemoteError.unsupported("Links can't be created across remote locations.")
                    case .copy, .move:
                        guard let dest = folder else { continue }
                        let name = src.lastPathComponent
                        if kind == .move, Self.sameLocation(src.deletingLastPathComponent(), dest) { continue }
                        if existing == nil { existing = try Self.names(in: dest) }
                        if existing?.contains(name) == true {
                            throw RemoteError.exists(name)
                        }
                        try Self.transferRemote(kind, src, into: dest)
                        existing?.insert(name)
                        results.append(dest.appendingPathComponent(name))
                    }
                } catch {
                    errors.append("\(src.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.jobsPanel.finish(row)
                Self.notifyChanged(urls + (folder.map { [$0] } ?? []) + results)
                if !errors.isEmpty { self.showErrors(errors, window: window) }
                done?(results)
            }
        }
    }

    /// Same folder, ignoring a trailing "/" (remote folder URLs carry one, typed ones may not).
    private static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String {
            let s = u.standardized
            var p = s.path
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return "\(s.scheme ?? "")://\(s.user ?? "")@\(s.host ?? ""):\(s.port ?? 0)\(p)"
        }
        return key(a) == key(b)
    }

    /// Names in a local or remote folder.
    private static func names(in folder: URL) throws -> Set<String> {
        if let p = RemoteFS.provider(for: folder) { return Set(try p.list(folder).map(\.name)) }
        return Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// One copy/move where the source, the destination or both are remote.
    private static func transferRemote(_ kind: FileOperationKind, _ src: URL, into dest: URL) throws {
        let fm = FileManager.default
        switch (RemoteFS.provider(for: src), RemoteFS.provider(for: dest)) {
        case let (s?, d?) where s === d:
            if kind == .copy { try s.copy([src], into: dest) } else { try s.move([src], into: dest) }
        case let (s?, nil):
            _ = try s.download(src, into: dest)
            if kind == .move { try s.delete([src]) }
        case let (nil, d?):
            try d.upload(src, into: dest)
            if kind == .move { try fm.removeItem(at: src) }
        case let (s?, d?):
            // Between two remote hosts: through a local temporary copy.
            let tmp = fm.temporaryDirectory.appendingPathComponent("xfer-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            try d.upload(try s.download(src, into: tmp), into: dest)
            if kind == .move { try s.delete([src]) }
        case (nil, nil):
            // A local item in a mixed local/remote selection (its name was checked to be free).
            guard src.isFileURL, dest.isFileURL else {
                throw RemoteError.unsupported("Items can't be put into “\(dest.absoluteString)”.")
            }
            let dst = dest.appendingPathComponent(src.lastPathComponent)
            if kind == .copy { try fm.copyItem(at: src, to: dst) } else { try fm.moveItem(at: src, to: dst) }
        }
    }

    // MARK: Trash origins ("Restore to Former Location")

    /// Original locations of items this app moved to the Trash (macOS has no public "Put Back" API).
    private var trashOrigins: [String: String] {
        get { Settings.store.dictionary(forKey: "trashOrigins") as? [String: String] ?? [:] }
        set { Settings.store.set(newValue, forKey: "trashOrigins") }
    }

    func recordTrash(_ record: UndoRecord) {
        guard case .trashed(let pairs) = record else { return }
        var d = trashOrigins
        for p in pairs { d[p.inTrash.path] = p.original.path }
        // Forget entries whose trash file is gone.
        d = d.filter { FileJob.itemExists(at: URL(fileURLWithPath: $0.key)) }
        trashOrigins = d
    }

    func originalLocation(of trashed: URL) -> URL? { trashOrigins[trashed.path].map { URL(fileURLWithPath: $0) } }

    /// Moves items back from the Trash to where they came from; returns the ones with unknown origins.
    func restore(_ urls: [URL], window: NSWindow?) -> [URL] {
        let fm = FileManager.default
        var unknown: [URL] = []
        var pairs: [(URL, URL)] = []
        for u in urls {
            guard let orig = originalLocation(of: u) else { unknown.append(u); continue }
            let parent = orig.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                var dest = orig
                if FileJob.itemExists(at: dest) {
                    let existing = Set((try? fm.contentsOfDirectory(atPath: parent.path)) ?? [])
                    dest = parent.appendingPathComponent(FileFormat.suggestedName(for: orig.lastPathComponent, existing: existing))
                }
                try fm.moveItem(at: u, to: dest)
                pairs.append((u, dest))
            } catch { showErrors([error.localizedDescription], window: window) }
        }
        if !pairs.isEmpty {
            pushUndo(.moved(pairs.map { (from: $0.0, to: $0.1) }))
            Self.notifyChanged(pairs.flatMap { [$0.0, $0.1] })
        }
        return unknown
    }

    // MARK: Undo

    func pushUndo(_ r: UndoRecord) {
        undoStack.append(r)
        redoStack.removeAll()
        NotificationCenter.default.post(name: Self.undoChanged, object: nil)
    }

    static func urls(of r: UndoRecord) -> [URL] {
        switch r {
        case .created(let u): return u
        case .moved(let p): return p.flatMap { [$0.from, $0.to] }
        case .trashed(let p): return p.flatMap { [$0.original, $0.inTrash] }
        case .renamed(let a, let b): return [a, b]
        }
    }

    var undoTitle: String? { undoStack.last.map { "Undo: \($0.label)" } }
    var redoTitle: String? { redoStack.last.map { "Redo: \($0.label)" } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo(window: NSWindow?) {
        guard let r = undoStack.popLast() else { return }
        switch revert(r) {
        case .success(let inverse): if let inverse { redoStack.append(inverse) }; stacksChanged()
        case .failure(let error): undoStack.append(r); stacksChanged(); showErrors([error.localizedDescription], window: window)
        }
    }

    func redo(window: NSWindow?) {
        guard let r = redoStack.popLast() else { return }
        switch revert(r) {
        case .success(let inverse): if let inverse { undoStack.append(inverse) }; stacksChanged()
        case .failure(let error): redoStack.append(r); stacksChanged(); showErrors([error.localizedDescription], window: window)
        }
    }

    /// FileActions.undo is all-or-nothing, so a record that failed is still valid and goes back on its
    /// stack for another try (e.g. after the user frees the original name). The stacks are changed by the
    /// callers before any alert: a job finishing during the alert pushes onto them.
    private func revert(_ r: UndoRecord) -> Result<UndoRecord?, Error> {
        do {
            let inverse = try FileActions.undo(r)
            if let inverse { Self.notifyChanged(Self.urls(of: inverse)) }
            return .success(inverse)
        } catch {
            return .failure(error)
        }
    }

    /// Administrator commands that rename `old` to `new`. A change of case only goes through a temporary name:
    /// on a case-insensitive volume `mv -n a A` sees "A" as existing and quietly does nothing.
    static func renameCommands(_ old: URL, to new: URL) -> [[String]] {
        guard old.path != new.path, old.path.lowercased() == new.path.lowercased() else { return [["/bin/mv", "-n", "--", old.path, new.path]] }
        let tmp = old.deletingLastPathComponent().appendingPathComponent(".porpoise-rename-\(UUID().uuidString)").path
        return [["/bin/mv", "-n", "--", old.path, tmp], ["/bin/mv", "-n", "--", tmp, new.path]]
    }

    private func stacksChanged() { NotificationCenter.default.post(name: Self.undoChanged, object: nil) }

    // MARK: Drop menu

    /// Dolphin asks what to do on drop unless a modifier was held: Move Here / Copy Here / Link Here / Cancel.
    func handleDrop(_ urls: [URL], onto folder: URL, operation: NSDragOperation, in view: NSView) {
        let urls = urls.filter { $0.standardizedFileURL != folder.standardizedFileURL }
        guard !urls.isEmpty else { return }
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }) { return }
        let w = view.window
        // Dropping into the Trash folder is Move to Trash, as in Finder (put back works, Finder's sound plays).
        if folder.standardizedFileURL == Self.trashFolder.standardizedFileURL, urls.allSatisfy(\.isFileURL) {
            trash(urls, window: w)
            return
        }
        switch operation {
        case .copy: run(.copy, urls, to: folder, window: w)
        case .move: run(.move, urls, to: folder, window: w)
        case .link: run(.link, urls, to: folder, window: w)
        default:
            let m = NSMenu()
            m.autoenablesItems = false
            let target = DropMenuTarget { [weak self] kind in self?.run(kind, urls, to: folder, window: w) }
            func add(_ title: String, _ key: String, _ icon: String, _ kind: FileOperationKind?) {
                let it = m.addItem(withTitle: title, action: #selector(DropMenuTarget.pick(_:)), keyEquivalent: "")
                it.target = target
                it.representedObject = kind?.rawValue
                it.image = Icons.shared.menuIcon(icon)
                if !key.isEmpty {
                    it.attributedTitle = NSAttributedString(string: title + "\t" + key, attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .paragraphStyle: { let p = NSMutableParagraphStyle(); p.tabStops = [NSTextTab(textAlignment: .right, location: 180)]; return p }(),
                    ])
                }
            }
            // Remote folders can't be checked locally (the provider reports errors); local ones owned by
            // someone else still accept drops, which then ask to authenticate. Only read-only volumes refuse.
            let writable = !folder.isFileURL || FileManager.default.isWritableFile(atPath: folder.path)
                || (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true
            let remote = !folder.isFileURL || urls.contains { !$0.isFileURL }
            add("Move Here", "⌘", "edit-move", .move)
            add("Copy Here", "⌥", "edit-copy", .copy)
            add("Link Here", "⌘⌥", "edit-link", .link)
            if !writable { m.items.forEach { $0.isEnabled = false } }
            if remote { m.items.last?.isEnabled = false }   // links can't point across remote locations
            m.addItem(.separator())
            add("Cancel", "Esc", "process-stop", nil)
            objc_setAssociatedObject(m, &dropTargetKey, target, .OBJC_ASSOCIATION_RETAIN)
            let loc = view.window?.mouseLocationOutsideOfEventStream ?? .zero
            m.popUp(positioning: nil, at: view.convert(loc, from: nil), in: view)
        }
    }
}

private var dropTargetKey = 0

private final class DropMenuTarget: NSObject {
    let handler: (FileOperationKind) -> Void
    init(_ h: @escaping (FileOperationKind) -> Void) { handler = h }
    @objc func pick(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let k = FileOperationKind(rawValue: raw) { handler(k) }
    }
}

// MARK: - Progress panel (KDE shows job progress in notifications; here a small floating panel)

final class JobRowView: NSView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let cancel = FlatButton(icon: "process-stop", tooltip: "Cancel")
    weak var job: FileJob?

    init(job: FileJob) {
        self.job = job
        super.init(frame: .zero)
        title.font = Theme.boldFont
        title.textColor = Theme.windowText
        detail.font = Theme.smallFont
        detail.textColor = Theme.windowTextInactive
        detail.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        cancel.onClick = { [weak self] in self?.job?.cancel() }
        for v in [title, detail, bar, cancel] as [NSView] { addSubview(v) }
        title.stringValue = job.kind.verb
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ p: JobProgress) {
        let dest = p.destination.map { " to \($0.lastPathComponent)" } ?? ""
        title.stringValue = "\(p.kind.verb) \(p.totalItems == 1 ? "1 item" : "\(p.totalItems) items")\(dest)"
        var d = p.currentName
        if p.totalBytes > 0 { d += " — \(FileFormat.size(p.doneBytes)) of \(FileFormat.size(p.totalBytes))" }
        detail.stringValue = d
        bar.doubleValue = p.fraction
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = CGRect(x: 12, y: 40, width: w - 52, height: 18)
        detail.frame = CGRect(x: 12, y: 22, width: w - 52, height: 16)
        bar.frame = CGRect(x: 12, y: 6, width: w - 52, height: 12)
        cancel.frame = CGRect(x: w - 36, y: 18, width: 28, height: 28)
    }
}

final class JobsPanel {
    /// Like KDE, progress only shows for jobs that take a moment.
    private static let showDelay: TimeInterval = 0.6
    private static let width: CGFloat = 380
    private static let rowHeight: CGFloat = 64
    private static let titleHeight: CGFloat = 28
    /// Distance from the screen's right and bottom edges.
    private static let margin: CGFloat = 20

    private var panel: NSPanel?
    private var rows: [JobRowView] = []
    private var showTimer: Timer?

    func add(_ job: FileJob) -> JobRowView {
        let row = JobRowView(job: job)
        rows.append(row)
        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in self?.relayout() }
        return row
    }

    func finish(_ row: JobRowView) {
        rows.removeAll { $0 === row }
        row.removeFromSuperview()
        if rows.isEmpty { panel?.orderOut(nil) } else { relayout() }
    }

    private func relayout() {
        guard !rows.isEmpty else { return }
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight + Self.titleHeight), styleMask: [.titled, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.title = "File Operations"
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.titlebarAppearsTransparent = true
            p.appearance = NSAppearance(named: .darkAqua)
            p.backgroundColor = Theme.windowBackground
            panel = p
        }
        guard let p = panel, let content = p.contentView else { return }
        let h = CGFloat(rows.count) * Self.rowHeight + Self.titleHeight
        content.subviews.forEach { $0.removeFromSuperview() }
        for (i, r) in rows.enumerated() {
            r.frame = CGRect(x: 0, y: h - Self.titleHeight - CGFloat(i + 1) * Self.rowHeight, width: Self.width, height: Self.rowHeight)
            content.addSubview(r)
        }
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrame(CGRect(x: vf.maxX - Self.width - Self.margin, y: vf.minY + Self.margin, width: Self.width, height: h), display: true)
        }
        p.orderFront(nil)
    }
}

// MARK: - Conflict dialog (KIO RenameDialog)

final class ConflictDialog: NSObject, NSTextFieldDelegate {
    let info: ConflictInfo
    let kind: FileOperationKind
    private var result = ConflictAnswer(.cancel)
    private let window: NSWindow
    private let nameField = NSTextField()
    private let applyAll = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
    private var renameButton: NSButton!

    init(info: ConflictInfo, kind: FileOperationKind) {
        self.info = info
        self.kind = kind
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let bothDirs = info.source.isBrowsableFolder && info.destination.isBrowsableFolder
        window.title = bothDirs ? "Folder Already Exists" : "File Already Exists"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBackground
        let v = window.contentView!
        let header = NSTextField(wrappingLabelWithString: bothDirs
            ? "Would you like to merge the contents of “\(info.source.name)” into “\(info.destination.url.deletingLastPathComponent().lastPathComponent)”?"
            : "This action will overwrite the destination.")
        header.font = Theme.boldFont
        header.frame = CGRect(x: 20, y: 286, width: 580, height: 34)
        v.addSubview(header)

        func pane(_ item: FileItem, title: String, x: CGFloat) {
            let box = NSView(frame: CGRect(x: x, y: 130, width: 280, height: 150))
            box.wantsLayer = true
            box.layer?.backgroundColor = Theme.viewBackground.cgColor
            box.layer?.cornerRadius = 5
            box.layer?.borderColor = Theme.frame.cgColor
            box.layer?.borderWidth = 1
            let t = NSTextField(labelWithString: title); t.font = Theme.boldFont; t.frame = CGRect(x: 10, y: 122, width: 260, height: 18)
            let img = NSImageView(frame: CGRect(x: 10, y: 40, width: 72, height: 72))
            img.image = Thumbnails.shared.thumbnail(for: item, size: 72) ?? Icons.shared.image(for: item, size: 72)
            let lines = [item.url.path,
                         item.isBrowsableFolder ? "Folder" : FileFormat.size(item.size),
                         item.modificationDate.map { "Modified: " + FileFormat.relativeDate($0) } ?? ""]
            for (i, l) in lines.enumerated() {
                let f = NSTextField(labelWithString: l)
                f.font = i == 0 ? Theme.smallFont : Theme.font
                f.lineBreakMode = .byTruncatingMiddle
                f.frame = CGRect(x: 90, y: 92 - CGFloat(i) * 22, width: 180, height: 18)
                box.addSubview(f)
            }
            box.addSubview(t)
            box.addSubview(img)
            v.addSubview(box)
        }
        pane(info.source, title: "Source", x: 20)
        pane(info.destination, title: "Destination", x: 320)

        // Comparison hint (KIO: "The source is more recent", "smaller by …", "identical").
        var hints: [String] = []
        if let s = info.source.modificationDate, let d = info.destination.modificationDate {
            if s > d { hints.append("The source is more recent.") } else if s < d { hints.append("The destination is more recent.") }
        }
        if !bothDirs {
            let diff = info.source.size - info.destination.size
            if diff > 0 { hints.append("The source is bigger by \(FileFormat.size(diff)).") }
            else if diff < 0 { hints.append("The source is smaller by \(FileFormat.size(-diff)).") }
            else if info.source.modificationDate == info.destination.modificationDate { hints.append("The files are identical.") }
        }
        let hint = NSTextField(labelWithString: hints.joined(separator: " "))
        hint.textColor = Theme.windowTextInactive
        hint.frame = CGRect(x: 20, y: 104, width: 580, height: 18)
        v.addSubview(hint)

        let renameLabel = NSTextField(labelWithString: "Rename:")
        renameLabel.frame = CGRect(x: 20, y: 72, width: 60, height: 20)
        nameField.stringValue = info.destination.name
        nameField.frame = CGRect(x: 84, y: 70, width: 340, height: 24)
        nameField.delegate = self
        let suggest = NSButton(title: "Suggest New Name", target: self, action: #selector(suggest))
        suggest.frame = CGRect(x: 430, y: 66, width: 170, height: 30)
        [renameLabel, nameField, suggest].forEach(v.addSubview)

        applyAll.frame = CGRect(x: 20, y: 22, width: 120, height: 20)
        v.addSubview(applyAll)

        var x: CGFloat = 600
        func button(_ title: String, _ sel: Selector, key: String = "") -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.keyEquivalent = key
            b.sizeToFit()
            b.frame.size.width += 12
            x -= b.frame.width + 6
            b.frame.origin = CGPoint(x: x, y: 16)
            v.addSubview(b)
            return b
        }
        _ = button("Cancel", #selector(cancel), key: "\u{1b}")
        _ = button("Skip", #selector(skip))
        if bothDirs {
            _ = button("Write Into", #selector(writeInto), key: "\r")
        } else {
            _ = button("Overwrite Older", #selector(overwriteOlder))
            _ = button("Overwrite", #selector(overwrite), key: "\r")
        }
        renameButton = button("Rename", #selector(rename))
        renameButton.isEnabled = false
    }

    func controlTextDidChange(_ obj: Notification) {
        renameButton.isEnabled = FileActions.isValidName(nameField.stringValue) && nameField.stringValue != info.destination.name
    }

    @objc private func suggest() {
        nameField.stringValue = info.suggestedName
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    private func finish(_ r: ConflictResolution) {
        result = ConflictAnswer(r, applyToAll: applyAll.state == .on)
        NSApp.stopModal()
        window.orderOut(nil)
    }

    @objc private func cancel() { finish(.cancel) }
    @objc private func skip() { finish(.skip) }
    @objc private func overwrite() { finish(.overwrite) }
    @objc private func overwriteOlder() { finish(.overwriteIfOlder) }
    @objc private func writeInto() { finish(.writeInto) }
    @objc private func rename() { finish(.rename(nameField.stringValue)) }

    func run() -> ConflictAnswer {
        window.center()
        NSApp.runModal(for: window)
        return result
    }
}
