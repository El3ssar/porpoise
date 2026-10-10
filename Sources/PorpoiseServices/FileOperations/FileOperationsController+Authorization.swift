import Foundation
import PorpoiseCore

// MARK: Permission denied → unlock your own items, or authenticate (as Finder does)

extension FileOperationsController {
    /// `targets` maps denied copy/move/link sources to where the job meant to put them (the job may have
    /// renamed them, and items from a merge go into subfolders); missing ones go to `folder`.
    /// `done` gets the items that ended up done: new copies/moves/links, or where trashed and deleted items were.
    func retryDenied(_ kind: FileOperationKind, _ urls: [URL], targets: [URL: URL], to folder: URL?,
                     window: AnyObject?, done: @escaping ([URL]) -> Void) {
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

        let plan = Self.administratorCommands(kind, remaining, targets: targets, to: folder)
        if !plan.skipped.isEmpty { showErrors(plan.skipped, window: window) }
        let ok = authorize(verb: Self.permissionVerb(kind), items: remaining, commands: plan.commands, window: window)
        // Remember where they came from, so "Restore" can put them back.
        if ok && !plan.trashed.isEmpty {
            recordTrash(.trashed(plan.trashed))
            // Yours from now on: emptying the Trash won't need the helper for them.
            PrivilegedHelper.takeOwnership(of: plan.trashed.map(\.inTrash.path))
        }
        Self.notifyChanged(remaining + (folder.map { [$0] } ?? []) + plan.results + plan.trashed.map(\.inTrash))
        done(unlocked + (ok ? plan.results + plan.trashed.map(\.inTrash) + (kind == .delete ? remaining : []) : []))
    }

    /// What to run as administrator for items the job wasn't allowed to touch: the commands, the items they create
    /// (`results`), where trashed ones go, and items left alone because their destination is taken (as messages).
    static func administratorCommands(_ kind: FileOperationKind, _ urls: [URL], targets: [URL: URL], to folder: URL?)
        -> (commands: [[String]], results: [URL], trashed: [(original: URL, inTrash: URL)], skipped: [String]) {
        var cmds: [[String]] = []
        var results: [URL] = []
        var skipped: [String] = []
        var trashNames = Set<String>()   // two denied items named alike must not land on the same name
        var trashPairs: [(original: URL, inTrash: URL)] = []
        for u in urls {
            switch kind {
            case .delete:
                cmds.append(["/usr/bin/chflags", "-R", "nouchg,noschg", u.path])
                cmds.append(["/bin/rm", "-rf", "--", u.path])
            case .trash:
                let dst = freeTrashURL(for: u, reserving: &trashNames)
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
        return (cmds, results, trashPairs, skipped)
    }

    /// Locked or read-only items you own: clears the lock and write protection, then tries again.
    /// Returns the items that still fail, and where trashed ones went.
    private func unlockOwnItems(_ urls: [URL], kind: FileOperationKind) -> (remaining: [URL], trashed: [(URL, URL)]) {
        let fm = FileManager.default
        var trashed: [(URL, URL)] = []
        let remaining = urls.filter { u in
            let owner = (try? fm.attributesOfItem(atPath: u.path)[.ownerAccountID] as? NSNumber)?.uint32Value
            guard owner == getuid() else { return true }
            // On a link, the link itself: -R doesn't follow one given by name, and -h stands for it otherwise.
            let scope = kind == .delete ? ["-R"] : ["-h"]
            _ = try? Shell.run("/usr/bin/chflags", scope + ["nouchg", u.path])
            _ = try? Shell.run("/bin/chmod", scope + ["u+w", u.path])
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

    static func permissionVerb(_ kind: FileOperationKind) -> String {
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
    static func freeTrashURL(for url: URL, reserving reserved: inout Set<String>) -> URL {
        var dst = TrashInfo.folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        while reserved.contains(dst.lastPathComponent) || FileJob.itemExists(at: dst) {
            dst = TrashInfo.folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        reserved.insert(dst.lastPathComponent)
        return dst
    }

    /// Finder's "authenticate to continue": runs the commands as administrator. Returns true if they ran
    /// successfully. Each command is a program and its arguments (see PorpoiseHelperInfo.allowedTools).
    @discardableResult
    public func authorize(verb: String, items: [URL], commands: [[String]], window: AnyObject?) -> Bool {
        guard !commands.isEmpty else { return false }
        if !Settings.isTesting {
            // Porpoise's helper does it at once, without asking. Not installed yet (or a new version of it): it's
            // installed once, with macOS's administrator dialog, and the action continues.
            guard PrivilegedHelper.ensureOn() else { return false }
            // Clearing lock flags is best effort, as in Finder; the operation itself reports what went wrong.
            switch PrivilegedHelper.run(commands, bestEffort: ["/usr/bin/chflags"]) {
            case .done: return true
            case .failed(let err): ui?.showAuthorizationError(err); return false
            case .unavailable(let why):
                ui?.showAuthorizationError("Porpoise's helper isn't responding (\(why)). If it's switched off under System Settings › General › Login Items & Extensions, switch it on and try again.")
                return false
            }
        }
        // Test instances never get root through the helper: the standard macOS prompt, after explaining.
        let q = Confirmation(
            message: items.count == 1 ? "Porpoise needs your permission to \(verb) “\(items[0].lastPathComponent)”."
                : "Porpoise needs your permission to \(verb) \(items.count) items.",
            detail: (items.count > 1 ? items.prefix(6).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ") + "\n\n" : "")
                + "These items belong to another user or the system. Authenticate as an administrator to continue, "
                + "or turn on Porpoise's helper in Porpoise › Permissions… to never be asked again.",
            confirmTitle: "Authenticate")
        guard confirm(q, window: window) else { return false }
        var err: NSDictionary?
        NSAppleScript(source: Self.administratorScript(commands))?.executeAndReturnError(&err)
        guard let err else { return true }
        if (err[NSAppleScript.errorNumber] as? Int) == Self.userCancelledError { return false }
        ui?.showAuthorizationError(err[NSAppleScript.errorMessage] as? String ?? "The operation failed.")
        return false
    }

    /// The AppleScript that runs `commands` in one administrator shell, stopping at the first failure (lock flags
    /// are cleared best effort).
    static func administratorScript(_ commands: [[String]]) -> String {
        let q = RemoteParsing.quote
        let shell = commands.map { c in
            let line = c.map(q).joined(separator: " ")
            return c.first == "/usr/bin/chflags" ? "( \(line) 2>/dev/null; true )" : "( \(line) )"
        }.joined(separator: " && ")
        return "do shell script \(Escaping.appleScriptString(shell)) with administrator privileges"
    }

    /// AppleScript's "User canceled." error number.
    private static let userCancelledError = -128

    /// Administrator commands that rename `old` to `new`. A change of case only goes through a temporary name:
    /// on a case-insensitive volume `mv -n a A` sees "A" as existing and quietly does nothing.
    public static func renameCommands(_ old: URL, to new: URL) -> [[String]] {
        guard old.path != new.path, old.path.lowercased() == new.path.lowercased() else { return [["/bin/mv", "-n", "--", old.path, new.path]] }
        let tmp = old.deletingLastPathComponent().appendingPathComponent(".porpoise-rename-\(UUID().uuidString)").path
        return [["/bin/mv", "-n", "--", old.path, tmp], ["/bin/mv", "-n", "--", tmp, new.path]]
    }
}
