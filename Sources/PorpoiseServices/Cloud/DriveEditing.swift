import Foundation
import PorpoiseCore

/// How an item being edited in another app shows on its row and in Activity.
public enum CloudEditMark: Equatable, Sendable {
    /// Open in another app: its saves go to Drive.
    case editing
    case saving
    /// Just saved (shown for a moment, then back to editing).
    case saved
    /// Saved here, not in Drive yet (offline, signed out, refused): kept, and sent again by itself.
    case unsent(String)
    /// Changed in Drive while it was edited here: both versions are kept until the user chooses.
    case conflict
    /// Saved here, on a service that can't yet take it as a new version safely: kept until saved as a copy in Drive.
    case needsCopy

    /// The badge on the item's icon.
    public var symbol: String {
        switch self {
        case .editing: return "pencil.circle.fill"
        case .saving: return "arrow.up.circle.fill"
        case .saved: return "checkmark.circle.fill"
        case .unsent: return "icloud.slash.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        case .needsCopy: return "doc.on.doc.fill"
        }
    }

    /// After the name, and in the status bar.
    public func note(_ service: String) -> String {
        switch self {
        case .editing: return "Editing · changes save to \(service)"
        case .saving: return "Saving to \(service)…"
        case .saved: return "Saved to \(service)"
        case .unsent: return "Not in \(service) yet · kept on this Mac"
        case .conflict: return "Changed in \(service) meanwhile · review in Activity"
        case .needsCopy: return "Saved on this Mac · save it as a copy in \(service)"
        }
    }

    /// Worth the user's attention (drawn in the warning color).
    public var needsAttention: Bool {
        switch self {
        case .conflict, .unsent, .needsCopy: return true
        default: return false
        }
    }
}

/// One Drive file being edited in another app, as Activity lists it.
public struct CloudEditEntry: Equatable, Sendable {
    public let id: UUID
    public let account: UUID
    /// The Drive file the copy's saves go to (after Keep Both, the new one next to the original).
    public var fileID: String
    public var name: String
    /// The copy the other app edits.
    public var localURL: URL
    /// Drive's version, downloaded when it changed meanwhile.
    public var conflictURL: URL?
    public var mark: CloudEditMark
    public var lastSaved: Date?
    /// Where the file is in Drive (the folder it was opened from).
    public var location: URL

    /// "Editing “Report.pdf”" and the like.
    public var title: String {
        switch mark {
        case .conflict: return "“\(name)” changed in Google Drive while you edited it"
        case .unsent: return "1 unsent edit to “\(name)”"
        case .needsCopy: return "Your changes to “\(name)” are on this Mac"
        default: return "Editing “\(name)”"
        }
    }

    /// The line under the title.
    public var detail: String {
        switch mark {
        case .editing:
            return lastSaved.map { "Changes save to Google Drive · last saved \($0.formatted(date: .omitted, time: .shortened))" }
                ?? "Changes you save in the other app go to Google Drive"
        case .saving: return "Saving to Google Drive…"
        case .saved: return "Saved to Google Drive"
        case .unsent(let why): return "\(why) Your changes are kept on this Mac and sent when they can be."
        case .conflict: return "Both versions are kept. Keep both as separate files, compare them, or make yours the current version."
        case .needsCopy:
            return "Google Drive can’t take them as a new version of the file yet. Save them as a copy next to it; the original stays as it is."
        }
    }
}

/// Drive files opened in other apps: their saves go back to Drive as new versions of the same file, only when Drive's
/// copy didn't change meanwhile (then both are kept and Activity asks). Saves that can't be sent are kept, survive a
/// quit, and go when they can. Main queue only.
public final class DriveEditing {
    public static let shared = DriveEditing()
    /// The marks or the list changed; `object` is nil.
    public static let changed = Notification.Name("PorpoiseDriveEditingChanged")

    /// Opens a local file in its app (set by the app).
    public var openFile: (URL) -> Void = { _ in }
    /// The client of an account (tests hand theirs).
    public var client: (UUID) -> DriveClient? = { id in
        (RemoteFS.provider(for: DriveLocation(accountID: id).url) as? DriveProvider)?.client
    }
    /// A burst of writes from one save is sent once, this long after the last.
    public var saveDelay: TimeInterval = 0.8
    /// How long "Saved to Google Drive" stays before the row goes back to "Editing".
    public var savedShownFor: TimeInterval = 4
    /// Whether saves can go to Drive as new versions of the file: only where Drive can refuse to overwrite someone
    /// else's version (the engine says so). Otherwise they stay here until saved as a copy.
    public var savesVersions: (DriveClient) -> Bool = { $0.canSaveEdits }
    /// Says something in the status bar (set by the app).
    public var post: (_ text: String, _ error: Bool) -> Void = { _, _ in }

    public private(set) var entries: [CloudEditEntry] = []
    private var watchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var pendingSave: [UUID: DispatchWorkItem] = [:]
    private var saving: Set<UUID> = []
    /// A save that came in while one was being sent: sent right after.
    private var saveAgain: Set<UUID> = []
    private var observers: [NSObjectProtocol] = []
    private var restored: Set<UUID> = []
    /// The app's instance lists unsent edits of earlier runs as accounts come up (tests call `restore` themselves).
    public var restoresAtLaunch = false

    public init() {
        observers.append(
            NotificationCenter.default.addObserver(forName: CloudAccounts.changed, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                // Accounts come up after launch: their unsent edits from an earlier run are listed once.
                let ids = CloudAccounts.shared.accounts.compactMap { UUID(uuidString: $0.id) }.filter { !self.restored.contains($0) }
                if !ids.isEmpty, self.restoresAtLaunch {
                    self.restored.formUnion(ids)
                    self.restore(accounts: ids)
                }
                self.retryUnsent()
            })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Marks

    /// The mark of the item at `url` (any spelling of its location), if it's being edited.
    public func mark(for url: URL) -> CloudEditMark? { entry(for: url)?.mark }

    public func entry(for url: URL) -> CloudEditEntry? {
        guard let location = DriveLocation(url: url), case .folder(let id, _) = location.collection else { return nil }
        return entries.first { $0.account == location.accountID && $0.fileID == id }
    }

    private func set(_ id: UUID, _ change: (inout CloudEditEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Opening

    /// Whether `item` can be edited in another app with its saves going back to Drive: a file (not a Google Doc) the
    /// account may change. Others open as a copy that stays on this Mac.
    public func canEdit(_ item: FileItem) -> Bool {
        guard let provider = RemoteFS.provider(for: item.url) as? DriveProvider, let file = provider.metadata(for: item.url),
            client(provider.accountID) != nil
        else { return false }
        return !file.isFolder && !file.isGoogleDocument && file.operations.canWrite && file.operations.canDownload
    }

    /// Opens a Drive file for editing in its app. `done(false)`: it can't be edited here (a copy should open instead).
    public func open(_ item: FileItem, done: @escaping (Bool) -> Void = { _ in }) {
        guard let location = DriveLocation(url: item.url), let client = client(location.accountID),
            let file = (RemoteFS.provider(for: item.url) as? DriveProvider)?.metadata(for: item.url), canEdit(item)
        else { return done(false) }
        // Already open: the same copy (with its edits) opens again.
        if let known = entries.first(where: { $0.account == location.accountID && $0.fileID == file.id }),
            FileManager.default.fileExists(atPath: known.localURL.path)
        {
            openFile(known.localURL)
            if watchers[known.id] == nil { watch(known.id) }
            return done(true)
        }
        post("Opening “\(item.name)”…", false)
        Task { @MainActor [weak self] in
            do {
                let session = try await client.edits.open(file)
                guard let self else { return }
                let entry = CloudEditEntry(
                    id: session.id, account: location.accountID, fileID: file.id, name: session.file.name, localURL: session.localURL,
                    conflictURL: session.conflictURL, mark: Self.mark(session.state, fresh: true), lastSaved: nil,
                    location: item.url)
                self.entries.removeAll { $0.id == entry.id }
                self.entries.insert(entry, at: 0)
                NotificationCenter.default.post(name: Self.changed, object: nil)
                self.openFile(session.localURL)
                self.watch(session.id)
                self.post(
                    self.savesVersions(client)
                        ? "Editing “\(entry.name)”: changes you save go to Google Drive."
                        : "Editing “\(entry.name)”: when you save, you can keep your changes as a copy in Google Drive.", false)
                done(true)
            } catch {
                self?.post("Couldn’t open “\(item.name)” for editing: \(error.localizedDescription)", false)
                done(false)
            }
        }
    }

    static func mark(_ state: DriveEditState, fresh: Bool = false) -> CloudEditMark {
        switch state {
        case .editing: return .editing
        case .saving: return .saving
        case .saved: return fresh ? .editing : .saved
        case .conflict: return .conflict
        case .unsent(let why): return .unsent(why)
        }
    }

    // MARK: Watching saves

    private func watch(_ id: UUID) {
        watchers.removeValue(forKey: id)?.cancel()
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let fd = Darwin.open(entry.localURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // Editors often save by replacing the file: watch the new one once the save settled.
            let replaced = source.data.contains(.rename) || source.data.contains(.delete)
            self.changed(id, replaced: replaced)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers[id] = source
    }

    private func changed(_ id: UUID, replaced: Bool) {
        pendingSave[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave[id] = nil
            if replaced { self.watch(id) }
            self.save(id)
        }
        pendingSave[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Sends the copy's saved changes to Drive (a conflict waits for the user instead).
    public func save(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), let client = client(entry.account) else { return }
        guard entry.mark != .conflict else { return }
        guard FileManager.default.fileExists(atPath: entry.localURL.path) else { return }
        guard savesVersions(client) else {
            // Nothing is sent: the changes wait, safe on this Mac, for "Save as a Copy in Drive".
            if entry.mark != .needsCopy {
                set(id) { $0.mark = .needsCopy }
                post("Your changes to “\(entry.name)” are kept on this Mac. Save them as a copy in Google Drive from Activity.", true)
            }
            return
        }
        guard saving.insert(id).inserted else { saveAgain.insert(id); return }
        set(id) { $0.mark = .saving }
        Task { @MainActor [weak self] in
            var failure: Error?
            do { _ = try await client.edits.save(id) } catch { failure = error }
            guard let self else { return }
            self.saving.remove(id)
            await self.finishSave(id, client: client, error: failure)
            if self.saveAgain.remove(id) != nil { self.save(id) }
        }
    }

    @MainActor private func finishSave(_ id: UUID, client: DriveClient, error: Error?) async {
        let session = await client.edits.session(id)
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if let session, session.state == .conflict || (error as? DriveMutationError) == .conflict {
            set(id) {
                $0.mark = .conflict
                $0.conflictURL = session.conflictURL
            }
            post("“\(entry.name)” changed in Google Drive while you edited it. Both versions are kept: review them in Activity.", true)
            return
        }
        if let error {
            let why = (error as? DriveError) == .offline ? "You’re offline." : "Google Drive didn’t take the changes: \(error.localizedDescription)"
            set(id) { $0.mark = .unsent(why) }
            post("Couldn’t save “\(entry.name)” to Google Drive yet. Your changes are kept on this Mac.", false)
            return
        }
        let now = Date()
        set(id) {
            $0.mark = .saved
            $0.lastSaved = now
            if let session { $0.name = session.file.name }
        }
        post("Saved “\(entry.name)” to Google Drive.", false)
        FileOperationsController.notifyChanged([entry.location])
        backToEditing(id)
    }

    /// "Saved" is a moment's confirmation: the row goes back to "Editing".
    private func backToEditing(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + savedShownFor) { [weak self] in
            guard let self, self.entries.first(where: { $0.id == id })?.mark == .saved else { return }
            self.set(id) { $0.mark = .editing }
        }
    }

    /// Unsent saves go again (the connection came back, or the user asked).
    public func retryUnsent() {
        for e in entries {
            guard case .unsent = e.mark, let client = client(e.account), !client.isOffline else { continue }
            save(e.id)
        }
    }

    // MARK: Conflicts

    /// Keeps Drive's version where it is and adds yours next to it as a separate file (also "Save as a Copy in Drive").
    public func keepBoth(_ id: UUID) {
        resolve(id, "Kept both versions of") { client in _ = try await client.edits.keepBoth(id) }
    }

    /// Makes yours the current version; Drive's stays in the file's version history.
    public func replaceWithMine(_ id: UUID) {
        resolve(id, "Saved your version of") { client in _ = try await client.edits.replaceWithMine(id) }
    }

    /// Opens Drive's version beside yours, to compare them.
    public func openBoth(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        openFile(entry.localURL)
        if let theirs = entry.conflictURL { openFile(theirs) }
    }

    private func resolve(_ id: UUID, _ done: String, _ action: @escaping (DriveClient) async throws -> Void) {
        guard let entry = entries.first(where: { $0.id == id }), entry.mark == .conflict || entry.mark == .needsCopy,
            let client = client(entry.account)
        else { return }
        let back = entry.mark
        set(id) { $0.mark = .saving }
        Task { @MainActor [weak self] in
            do {
                try await action(client)
                let session = await client.edits.session(id)
                guard let self else { return }
                self.set(id) {
                    $0.mark = .saved
                    $0.conflictURL = nil
                    $0.lastSaved = Date()
                    // Keep Both: the other app's saves now go to the new file.
                    if let file = session?.file {
                        $0.fileID = file.id
                        $0.name = file.name
                    }
                }
                self.post("\(done) “\(entry.name)” in Google Drive.", false)
                FileOperationsController.notifyChanged([entry.location])
                self.backToEditing(id)
            } catch {
                guard let self else { return }
                self.set(id) { $0.mark = back }
                self.post("Couldn’t do that with “\(entry.name)”: \(error.localizedDescription) Your changes are still kept.", true)
            }
        }
    }

    // MARK: Launch and quitting

    /// Edits saved in an earlier run that never reached Drive: listed as unsent, and sent now when possible.
    public func restore(accounts: [UUID]) {
        for account in accounts {
            guard let client = client(account) else { continue }
            Task { @MainActor [weak self] in
                let pending = await client.edits.pending()
                guard let self, !pending.isEmpty else { return }
                for session in pending where !self.entries.contains(where: { $0.id == session.id }) {
                    let mark: CloudEditMark =
                        session.state == .conflict ? .conflict : .unsent("Saved before Porpoise quit, not in Google Drive yet.")
                    self.entries.append(
                        CloudEditEntry(
                            id: session.id, account: account, fileID: session.file.id, name: session.file.name, localURL: session.localURL,
                            conflictURL: session.conflictURL, mark: mark, lastSaved: nil,
                            location: session.file.location(accountID: account).url))
                }
                NotificationCenter.default.post(name: Self.changed, object: nil)
                if !client.isOffline { self.retryUnsent() }
            }
        }
    }

    /// Takes a finished edit off the list (its copy stays until the engine clears it).
    public func dismiss(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), entry.mark == .editing || entry.mark == .saved else { return }
        watchers.removeValue(forKey: id)?.cancel()
        pendingSave.removeValue(forKey: id)?.cancel()
        entries.removeAll { $0.id == id }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Edits that still need something: unsent, or waiting for a choice.
    public var needingAttention: [CloudEditEntry] { entries.filter(\.mark.needsAttention) }
}
