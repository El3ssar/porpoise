import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseHelperKit

// MARK: Permission denied → unlock your own items, or authenticate (as Finder does)

extension FileOperationsController {
    /// `targets` maps denied copy/move/link sources to where the job meant to put them (the job may have
    /// renamed them, and items from a merge go into subfolders); missing ones go to `folder`.
    /// `done` gets the items that ended up done: new copies/moves/links, or where trashed and deleted items were.
    func retryDenied(
        _ kind: FileOperationKind, _ urls: [URL], targets: [URL: URL], to folder: URL?,
        window: AnyObject?, allowAuthorization: Bool = true, done: @escaping ([URL]) -> Void
    ) {
        guard allowAuthorization else { done([]); return }
        guard kind == .delete || kind == .trash else {
            return finishRetryDenied(kind, urls, remaining: urls, unlocked: [], targets: targets, to: folder, window: window, done: done)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (remaining, trashed) = self.unlockOwnItems(urls, kind: kind)
            TrashService.shared.flush()
            DispatchQueue.main.async {
                if !trashed.isEmpty {
                    self.pushUndo(.trashed(trashed.map { (original: $0.0, inTrash: $0.1) }))
                }
                let unlocked = trashed.map(\.1) + (kind == .delete ? urls.filter { !remaining.contains($0) } : [])
                self.finishRetryDenied(
                    kind, urls, remaining: remaining, unlocked: unlocked, targets: targets, to: folder, window: window, done: done)
            }
        }
    }

    private func finishRetryDenied(
        _ kind: FileOperationKind, _ urls: [URL], remaining: [URL], unlocked: [URL], targets: [URL: URL], to folder: URL?,
        window: AnyObject?, done: @escaping ([URL]) -> Void
    ) {
        guard !remaining.isEmpty else { Self.notifyChanged(urls); done(unlocked); return }

        let plan = Self.administratorCommands(kind, remaining, targets: targets, to: folder)
        if !plan.skipped.isEmpty { showErrors(plan.skipped, window: window) }
        authorize(verb: Self.permissionVerb(kind), items: remaining, commands: plan.commands, kind: kind, window: window) { [self] ok in
            // Remember where they came from, so "Restore" can put them back.
            if ok && !plan.trashed.isEmpty {
                pushUndo(.trashed(plan.trashed))
                TrashService.shared.record(plan.trashed)
                // Yours from now on: emptying the Trash won't need the helper for them.
                PrivilegedHelper.takeOwnership(of: plan.trashed.map(\.inTrash.path))
            }
            Self.notifyChanged(remaining + (folder.map { [$0] } ?? []) + plan.results + plan.trashed.map(\.inTrash))
            done(unlocked + (ok ? plan.results + plan.trashed.map(\.inTrash) + (kind == .delete ? remaining : []) : []))
        }
    }

    /// What to run as administrator for items the job wasn't allowed to touch: the commands, the items they create
    /// (`results`), where trashed ones go, and items left alone because their destination is taken (as messages).
    static func administratorCommands(_ kind: FileOperationKind, _ urls: [URL], targets: [URL: URL], to folder: URL?)
        -> (commands: [[String]], results: [URL], trashed: [(original: URL, inTrash: URL)], skipped: [String])
    {
        var cmds: [[String]] = []
        var results: [URL] = []
        var skipped: [String] = []
        var trashNames = Set<String>()  // two denied items named alike must not land on the same name
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
            Self.unlockForRemoval(u, recursively: kind == .delete)
            do {
                if kind == .delete {
                    try fm.removeItem(at: u)
                } else {
                    trashed += try TrashService.shared.trash([u])
                }
                return false
            } catch {
                return true
            }
        }
        return (remaining, trashed)
    }

    /// lstat/lchflags/lchmod act on links themselves; recursive deletion never unlocks a link's target.
    static func unlockForRemoval(_ url: URL, recursively: Bool) {
        func unlock(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return }
            _ = lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE))
            _ = lchmod(path, (info.st_mode & 0o7777) | mode_t(S_IWUSR))
        }
        unlock(url.path)
        var info = stat()
        guard recursively, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        while let relative = autoreleasepool(invoking: { enumerator?.nextObject() as? String }) {
            autoreleasepool { unlock(url.appendingPathComponent(relative).path) }
        }
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
    /// Runs `commands` as administrator and waits: for quick, single-item actions (a new item, a permission change).
    /// File operations use the `done:` form, which works off the main thread.
    public func authorize(verb: String, items: [URL], commands: [[String]], window: AnyObject?) -> Bool {
        guard let viaHelper = confirmAuthorization(verb: verb, items: items, commands: commands, window: window) else { return false }
        return report(Self.elevate(commands, viaHelper))
    }

    /// Runs `commands` as administrator off the main thread, shown as their own Activity (they may copy or delete a
    /// lot as root); only the confirmation is asked here. `done(true)` once they ran.
    public func authorize(
        verb: String, items: [URL], commands: [[String]], kind: FileOperationKind, window: AnyObject?, done: @escaping (Bool) -> Void
    ) {
        guard let viaHelper = confirmAuthorization(verb: verb, items: items, commands: commands, window: window) else { return done(false) }
        let activity = Activity(kind: kind, sources: items, destination: nil, job: nil, pauseUnavailable: "Actions as administrator can't be paused.")
        activity.cloudTitle = "As administrator: \(verb)"
        activity.originWindow = window
        activities.append(activity)
        began(activity)
        ui?.jobStarted(activity)
        activityDidChange()
        let elevate = Self.elevate
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = elevate(commands, viaHelper)
            DispatchQueue.main.async { [self] in
                let ok = report(outcome)
                if case .cancelled = outcome { activity.control.cancel() }
                if case .failed(let message) = outcome { ended(activity, errors: [message]) } else { ended(activity, errors: []) }
                ui?.jobFinished(activity)
                done(ok)
            }
        }
    }

    /// What running commands as administrator came to.
    public enum ElevatedOutcome: Equatable, Sendable {
        case done, cancelled
        case failed(String)
    }

    /// Asks before anything runs as administrator: nil when it won't (nothing to run, or the person said no);
    /// otherwise whether it goes through Porpoise's helper (which needs no question each time).
    private func confirmAuthorization(verb: String, items: [URL], commands: [[String]], window: AnyObject?) -> Bool? {
        #if PORPOISE_TEST_HOOKS
        authorizationAttempted?()
        #endif
        guard !commands.isEmpty else { return nil }
        // Standard users never use the helper (it's for administrators): macOS's prompt, for an administrator's
        // name and password.
        if !Settings.isTesting && PrivilegedHelper.isForThisUser { return true }
        // Test instances and standard users never get root through the helper: the standard macOS prompt, after explaining.
        let q = Confirmation(
            message: items.count == 1
                ? "Porpoise needs your permission to \(verb) “\(items[0].lastPathComponent)”."
                : "Porpoise needs your permission to \(verb) \(items.count) items.",
            detail: (items.count > 1 ? items.prefix(6).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ") + "\n\n" : "")
                + "These items belong to another user or the system. Authenticate as an administrator to continue"
                + (PrivilegedHelper.isForThisUser ? ", or turn on Porpoise's helper in Porpoise › Permissions… to never be asked again." : "."),
            confirmTitle: "Authenticate")
        return confirm(q, window: window) ? false : nil
    }

    /// Shows what went wrong, if anything; true if the commands ran.
    private func report(_ outcome: ElevatedOutcome) -> Bool {
        switch outcome {
        case .done: return true
        case .cancelled: return false
        case .failed(let message): ui?.showAuthorizationError(message); return false
        }
    }

    /// Runs `commands` as root, on any thread: through Porpoise's helper (installed or updated first, with one
    /// approval, if needed), or after macOS's administrator prompt. Tests replace it.
    nonisolated(unsafe) static var elevate: ([[String]], Bool) -> ElevatedOutcome = { commands, viaHelper in
        if viaHelper {
            // Porpoise's helper does it at once, without asking. Not installed yet (or a new version of it): it's
            // installed once, with macOS's administrator dialog, and the action continues.
            guard PrivilegedHelper.ensureOn() else { return .cancelled }
            // Clearing lock flags is best effort, as in Finder; the operation itself reports what went wrong.
            switch PrivilegedHelper.run(commands, bestEffort: ["/usr/bin/chflags"]) {
            case .done: return .done
            case .failed(let err): return .failed(err)
            case .unavailable(let why):
                return .failed(
                    "Porpoise's helper isn't responding (\(why)). If it's switched off under System Settings › General › Login Items & Extensions, switch it on and try again."
                )
            }
        }
        // osascript, in a process of its own: AppleScript stays off this process's threads, and macOS shows its prompt.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", administratorScript(commands)]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .done }
        if message.contains("(\(userCancelledError))") { return .cancelled }
        return .failed(FileOperationsController.osascriptMessage(message))
    }

    /// osascript's error line without its "0:12: execution error: " prefix and "(-60005)" suffix.
    static func osascriptMessage(_ stderr: String) -> String {
        var m = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = m.range(of: "execution error: ") { m = String(m[r.upperBound...]) }
        if let r = m.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { m.removeSubrange(r) }
        return m.isEmpty ? "The operation failed." : m
    }

    /// The AppleScript that runs `commands` in one administrator shell, stopping at the first failure (lock flags
    /// are cleared best effort). Its prompt names Porpoise: run by osascript, macOS would otherwise say "osascript".
    static func administratorScript(_ commands: [[String]]) -> String {
        let q = RemoteParsing.quote
        let shell = commands.map { c in
            let line = c.map(q).joined(separator: " ")
            return c.first == "/usr/bin/chflags" ? "( \(line) 2>/dev/null; true )" : "( \(line) )"
        }.joined(separator: " && ")
        return "do shell script \(Escaping.appleScriptString(shell)) with prompt \(Escaping.appleScriptString(administratorPrompt))"
            + " with administrator privileges"
    }

    static let administratorPrompt = "Porpoise needs an administrator’s permission to make this change."

    /// AppleScript's "User canceled." error number.
    static let userCancelledError = -128

    /// Administrator commands that rename `old` to `new`. A change of case only goes through a temporary name:
    /// on a case-insensitive volume `mv -n a A` sees "A" as existing and quietly does nothing.
    public static func renameCommands(_ old: URL, to new: URL) -> [[String]] {
        guard old.path != new.path, old.path.lowercased() == new.path.lowercased() else { return [["/bin/mv", "-n", "--", old.path, new.path]] }
        let tmp = old.deletingLastPathComponent().appendingPathComponent(".porpoise-rename-\(UUID().uuidString)").path
        return [["/bin/mv", "-n", "--", old.path, tmp], ["/bin/mv", "-n", "--", tmp, new.path]]
    }
}
