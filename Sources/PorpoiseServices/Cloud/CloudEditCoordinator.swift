import Foundation
import PorpoiseCore

/// A type-erased account binding; provider-specific operations finish at this boundary.
private struct CloudEditBinding {
    var key: String
    var provider: CloudProvider
    /// The selected file's revision, as its folder listed it.
    var revision: String?
    var offline: () -> Bool
    var cached: () async -> CloudEditEntry?
    var open: (CloudTransferContext) async throws -> CloudEditEntry
    var pending: () async -> [CloudEditEntry]
    var session: (UUID) async -> CloudEditEntry?
    var save: (UUID) async throws -> Void
    var copy: (UUID) async throws -> Void
    var replace: (UUID) async throws -> Void
    var release: (UUID) async -> Void
    var compare: (CloudEditEntry) async throws -> URL?

    init<E: CloudEditEngine>(
        store: CloudEditSessionStore<E>, file: E.File?, account: UUID, provider: CloudProvider, namespace: String? = nil,
        offline: @escaping () -> Bool,
        name: @escaping (E.File) -> String, location: @escaping (E.File) -> URL,
        copyPath: @escaping (E.File) async throws -> String,
        compare: @escaping (CloudEditEntry) async throws -> URL? = { $0.conflictURL }
    ) {
        key = "\(provider):\(account):\(namespace ?? "")"
        self.provider = provider; self.offline = offline; self.compare = compare
        revision = file.flatMap(store.engine.revision)
        func entry(_ session: CloudEditSession<E.File>) -> CloudEditEntry {
            CloudEditEntry(
                id: session.id, account: account, fileID: store.engine.identity(session.file), name: name(session.file),
                localURL: session.localURL, conflictURL: session.conflictURL, mark: CloudEditCoordinator.mark(session.state),
                location: location(session.file), provider: provider, revision: store.engine.revision(session.file))
        }
        cached = {
            guard let file, let session = await store.cachedSession(file) else { return nil }
            await store.retainCopy(session.id); return entry(session)
        }
        open = { context in
            guard let file else { throw store.engine.unavailable }
            return entry(try await store.openSession(file, context: context))
        }
        pending = { await store.pending().map(entry) }
        session = { id in await store.session(id).map(entry) }
        save = { id in _ = try await store.saveSession(id) }
        copy = { id in
            guard let session = await store.session(id) else { throw store.engine.unavailable }
            _ = try await store.saveSession(id, copyPath: copyPath(session.file))
        }
        replace = { id in _ = try await store.replaceSession(id) }
        release = { id in await store.releaseCopy(id) }
    }
}

/// One main-queue editing flow for all cloud accounts. Only account bindings know the provider APIs.
public final class CloudEditCoordinator {
    public static let shared = CloudEditCoordinator()
    public static let changed = Notification.Name("PorpoiseCloudEditingChanged")
    public var openFile: (URL) -> Void = { _ in }
    public var post: (String, Bool) -> Void = { _, _ in }
    public var client: (UUID) -> DriveClient? = { id in
        (RemoteFS.provider(for: DriveLocation(accountID: id).url) as? DriveProvider)?.client
    }
    public var saveDelay: TimeInterval = 0.8
    public var savedShownFor: TimeInterval = 4
    public var operations: FileOperationsController = .shared
    public var restoresAtLaunch = false {
        didSet { if restoresAtLaunch { restoreRegistered() } }
    }
    public private(set) var entries: [CloudEditEntry] = []
    private var bindings: [UUID: CloudEditBinding] = [:]
    private var registered: [String: CloudEditBinding] = [:]
    private var restored: Set<String> = []
    private var watchers: [UUID: SaveWatcher] = [:]
    private var saving: Set<UUID> = []
    private var saveAgain: Set<UUID> = []
    private var observer: NSObjectProtocol?
    public init() {
        observer = NotificationCenter.default.addObserver(forName: CloudAccounts.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.restoresAtLaunch {
                self.restore(accounts: CloudAccounts.shared.accounts.compactMap { UUID(uuidString: $0.id) })
                self.restoreRegistered()
            }
            self.retryUnsent()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    public func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }
    public func entry(for url: URL) -> CloudEditEntry? {
        if let location = DriveLocation(url: url), case .folder(let id, _) = location.collection {
            return entries.first { $0.provider == .googleDrive && $0.account == location.accountID && $0.fileID == id }
        }
        if let location = OneDriveLocation(url: url) {
            return entries.first {
                $0.provider == .oneDrive && $0.account == location.accountID && $0.fileID == location.itemID
                    && OneDriveLocation(url: $0.location)?.driveID == location.driveID
            }
        }
        if let location = BoxLocation(url: url) {
            return entries.first { $0.provider == .box && $0.account == location.accountID && $0.fileID == location.apiID }
        }
        if let location = DropboxLocation(url: url) {
            return entries.first {
                $0.provider == .dropbox && $0.account == location.accountID && $0.fileID == location.itemID
                    && DropboxLocation(url: $0.location)?.namespaceID == location.namespaceID
            }
        }
        return nil
    }
    public func mark(for url: URL) -> CloudEditMark? { entry(for: url)?.mark }
    static func mark(_ state: CloudEditState, fresh: Bool = false) -> CloudEditMark {
        switch state {
        case .editing: return .editing
        case .saving: return .saving
        case .saved: return fresh ? .editing : .saved
        case .conflict: return .conflict
        case .unsent(let why): return .unsent(why)
        }
    }
    private func changed() { NotificationCenter.default.post(name: Self.changed, object: nil) }
    private func set(_ id: UUID, _ change: (inout CloudEditEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i]); changed()
    }
    private func drive(_ client: DriveClient, file: DriveFile? = nil) -> CloudEditBinding {
        let account = client.accountID
        return CloudEditBinding(
            store: client.edits, file: file, account: account, provider: .googleDrive,
            offline: { [weak client] in client?.isOffline ?? true }, name: { $0.name }, location: { $0.location(accountID: account).url },
            copyPath: { _ in "copy" })
    }
    private func dropbox(_ client: DropboxClient, file: DropboxItem? = nil) -> CloudEditBinding {
        let account = client.accountID, namespace = client.namespaceID
        return CloudEditBinding(
            store: client.edits, file: file, account: account, provider: .dropbox, namespace: namespace,
            offline: { [weak client] in client?.isOffline ?? true }, name: { $0.name },
            location: { DropboxLocation(accountID: account, itemID: $0.id, namespaceID: namespace).url },
            copyPath: { [weak client] file in
                guard let client else { throw DropboxError.reconnect }
                let files = try await client.list(file.parentPath)
                return try DropboxClient.childPath(
                    name: FileFormat.suggestedName(for: file.name, existing: Set(files.map(\.name))), parent: file.parentPath)
            },
            compare: { [weak client] entry in
                guard let client else { throw DropboxError.reconnect }
                return try await client.open(client.metadata(entry.fileID))
            })
    }
    private func oneDrive(_ client: OneDriveClient, file: OneDriveItem? = nil) -> CloudEditBinding {
        let account = client.accountID, drive = client.driveID
        return CloudEditBinding(
            store: client.edits, file: file, account: account, provider: .oneDrive, namespace: drive,
            offline: { [weak client] in client?.isOffline ?? true }, name: { $0.name },
            location: { OneDriveLocation(accountID: account, itemID: $0.id, driveID: $0.driveID ?? drive).url },
            copyPath: { [weak client] file in
                guard let client, let parent = file.parentID else { throw OneDriveError.reconnect }
                let files = try await client.list(parent == client.rootID ? "" : parent)
                return FileFormat.suggestedName(for: file.name, existing: Set(files.map(\.name)))
            },
            compare: { [weak client] entry in
                guard let client else { throw OneDriveError.reconnect }
                return try await client.open(client.metadata(entry.fileID))
            })
    }
    private func box(_ client: BoxClient, file: BoxItem? = nil) -> CloudEditBinding {
        let account = client.accountID
        return CloudEditBinding(
            store: client.edits, file: file, account: account, provider: .box,
            offline: { [weak client] in client?.isOffline ?? true }, name: { $0.name },
            location: { BoxLocation(accountID: account, itemID: $0.id, kind: $0.kind).url },
            copyPath: { [weak client] file in
                guard let client, let parent = file.parentID else { throw BoxError.reconnect }
                let files = try await client.list(parent)
                return FileFormat.suggestedName(for: file.name, existing: Set(files.map(\.name)))
            },
            compare: { [weak client] entry in
                guard let client else { throw BoxError.reconnect }
                return try await client.open(client.metadata(entry.fileID, kind: .file))
            })
    }
    private func binding(_ item: FileItem, checkAccount: Bool = true) -> CloudEditBinding? {
        guard !item.isBrowsableFolder else { return nil }
        if let provider = RemoteFS.provider(for: item.url) as? DriveProvider,
            let file = provider.metadata(for: item.url), let client = client(provider.accountID),
            !file.isFolder, !file.isGoogleDocument, file.operations.canWrite, file.operations.canDownload
        {
            return drive(client, file: file)
        }
        if let provider = RemoteFS.provider(for: item.url) as? DropboxProvider,
            let file = provider.metadata(item.url), file.rev != nil, file.isDownloadable != false,
            (!checkAccount || CloudAccounts.shared.accountDenial(for: item.url) == nil), let client = try? provider.scoped(item.url)
        {
            return dropbox(client, file: file)
        }
        if let provider = RemoteFS.provider(for: item.url) as? OneDriveProvider,
            let file = provider.metadata(item.url), file.revision != nil, file.canDownload,
            (!checkAccount || CloudAccounts.shared.accountDenial(for: item.url) == nil), let client = try? provider.scoped(item.url)
        {
            return oneDrive(client, file: file)
        }
        if let provider = RemoteFS.provider(for: item.url) as? BoxProvider,
            let file = provider.metadata(item.url), file.revision != nil, file.etag != nil, file.canDownload,
            (!checkAccount || CloudAccounts.shared.accountDenial(for: item.url) == nil)
        {
            return box(provider.client, file: file)
        }
        return nil
    }
    public func canEdit(_ item: FileItem) -> Bool { binding(item) != nil }
    public func open(_ item: FileItem, using launch: ((URL) -> Void)? = nil, done: @escaping (Bool) -> Void = { _ in }) {
        let launch = launch ?? openFile
        guard let binding = binding(item, checkAccount: false) else { done(false); return }
        let known = entry(for: item.url)
        // A clean copy of an older revision is replaced; changed or conflicted bytes are always reopened.
        if let known, FileManager.default.fileExists(atPath: known.localURL.path),
            known.revision == binding.revision || (known.mark != .editing && known.mark != .saved)
        {
            launch(known.localURL); if watchers[known.id] == nil { watch(known.id) }; done(true); return
        }
        post("Opening “\(item.name)”…", false)
        Task { @MainActor [weak self] in
            do {
                let cached = await binding.cached()
                var opened: CloudEditEntry?
                _ = try await CloudRemoteOpen.prepare(item, cached: cached?.localURL, operations: self?.operations ?? .shared) { context in
                    let entry = try await binding.open(context); opened = entry; return entry.localURL
                }
                guard var entry = opened ?? cached else { throw DriveError.invalidResponse }
                guard let self else { done(true); return }
                if entry.mark == .saved { entry.mark = .editing }
                entry.location = item.url
                // The older copy goes unless the other app saved it meanwhile; then it stays to be sent.
                if let known, known.id != entry.id, !(await binding.pending()).contains(where: { $0.id == known.id }) {
                    self.dismiss(known.id)
                }
                self.add(entry, binding: binding); launch(entry.localURL); self.watch(entry.id)
                self.post("Editing “\(entry.name)”: changes you save go to \(binding.provider.title).", false)
                done(true)
            } catch {
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    self?.post("Couldn’t open “\(item.name)” for editing: \(error.localizedDescription)", true)
                }
                done(true)
            }
        }
    }
    private func add(_ entry: CloudEditEntry, binding: CloudEditBinding) {
        bindings[entry.id] = binding
        entries.removeAll { $0.id == entry.id }; entries.insert(entry, at: 0); changed()
    }
    private func watch(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        watchers[id] = SaveWatcher(entry.localURL, delay: saveDelay, queue: .main) { [weak self] in self?.save(id) }
    }
    public func save(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), let binding = bindings[id], entry.mark != .conflict,
            FileManager.default.fileExists(atPath: entry.localURL.path)
        else { return }
        guard saving.insert(id).inserted else { saveAgain.insert(id); return }
        set(id) { $0.mark = .saving }
        Task { @MainActor [weak self] in
            var failure: Error?
            do { try await binding.save(id) } catch { failure = error }
            let session = await binding.session(id)
            guard let self else { return }
            self.saving.remove(id)
            if let session, session.mark == .conflict {
                self.set(id) {
                    $0.mark = .conflict; $0.conflictURL = session.conflictURL
                }
                self.post(
                    "“\(entry.name)” changed in \(entry.provider.title) while you edited it. Both versions are kept: review them in Activity.", true)
            } else if let failure {
                let why = binding.offline() ? "You’re offline." : "\(entry.provider.title) didn’t take the changes: \(failure.localizedDescription)"
                self.set(id) { $0.mark = .unsent(why) }
                self.post("Couldn’t save “\(entry.name)” to \(entry.provider.title) yet. Your changes are kept on this Mac.", false)
            } else if let session, case .unsent = session.mark {
                self.set(id) { $0.mark = session.mark }; self.saveAgain.insert(id)
            } else {
                self.set(id) {
                    $0.mark = .saved; $0.lastSaved = Date()
                    if let session { $0.name = session.name; $0.revision = session.revision }
                }
                self.post("Saved “\(entry.name)” to \(entry.provider.title).", false)
                FileOperationsController.notifyChanged([entry.location]); self.backToEditing(id)
            }
            if self.saveAgain.remove(id) != nil { self.save(id) }
        }
    }
    private func backToEditing(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + savedShownFor) { [weak self] in
            guard let self, self.entries.first(where: { $0.id == id })?.mark == .saved else { return }
            self.set(id) { $0.mark = .editing }
        }
    }
    public func retryUnsent() {
        for entry in entries where !saving.contains(entry.id) {
            if case .unsent = entry.mark, bindings[entry.id]?.offline() == false { save(entry.id) }
        }
    }
    public func keepBoth(_ id: UUID) { resolve(id, "Kept both versions of", copy: true) }
    public func replaceWithMine(_ id: UUID) { resolve(id, "Saved your version of", copy: false) }
    public func replace(_ id: UUID) { replaceWithMine(id) }
    private func resolve(_ id: UUID, _ message: String, copy: Bool) {
        guard let entry = entries.first(where: { $0.id == id }), (copy || entry.mark == .conflict),
            let binding = bindings[id], saving.insert(id).inserted
        else { return }
        set(id) { $0.mark = .saving }
        Task { @MainActor [weak self] in
            do {
                if copy { try await binding.copy(id) } else { try await binding.replace(id) }
                let session = await binding.session(id)
                guard let self else { return }
                self.saving.remove(id)
                self.set(id) {
                    $0.mark = session?.mark ?? .saved; $0.conflictURL = nil; $0.lastSaved = Date()
                    if let session { $0.fileID = session.fileID; $0.name = session.name; $0.revision = session.revision }
                }
                self.post("\(message) “\(entry.name)” in \(entry.provider.title).", false)
                FileOperationsController.notifyChanged([entry.location]); self.backToEditing(id)
                if self.saveAgain.remove(id) != nil { self.save(id) }
            } catch {
                guard let self else { return }
                self.saving.remove(id); self.set(id) { $0.mark = entry.mark }
                self.post("Couldn’t do that with “\(entry.name)”: \(error.localizedDescription) Your changes are still kept.", true)
            }
        }
    }
    public func openBoth(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), let binding = bindings[id] else { return }
        openFile(entry.localURL)
        if let theirs = entry.conflictURL { openFile(theirs); return }
        Task { @MainActor [weak self] in
            do { if let url = try await binding.compare(entry) { self?.openFile(url) } } catch { self?.post(error.localizedDescription, true) }
        }
    }
    /// Backend registration is independent of launch recovery; tests may explicitly restore Drive accounts.
    public func restore(_ client: DropboxClient) {
        register(dropbox(client))
        if restoresAtLaunch { restoreRegistered() }
    }
    public func restore(_ client: OneDriveClient) {
        register(oneDrive(client))
        if restoresAtLaunch { restoreRegistered() }
    }
    public func restore(_ client: BoxClient) {
        register(box(client))
        if restoresAtLaunch { restoreRegistered() }
    }
    private func register(_ binding: CloudEditBinding) {
        registered[binding.key] = binding
        // Reconnection may install a new client for the same account; existing edits use its recovered store.
        for entry in entries where bindings[entry.id]?.key == binding.key { bindings[entry.id] = binding }
    }
    private func restoreRegistered() {
        for (key, binding) in registered where restored.insert(key).inserted { restore(binding) }
    }
    public func restore(accounts: [UUID]) {
        for id in accounts {
            guard let client = client(id) else { continue }
            let binding = drive(client); register(binding)
            if restored.insert(binding.key).inserted { restore(binding) }
        }
    }
    private func restore(_ binding: CloudEditBinding) {
        Task { @MainActor [weak self] in
            let pending = await binding.pending()
            guard let self else { return }
            for var entry in pending where !self.contains(entry.id) {
                if entry.mark != .conflict { entry.mark = .unsent("Saved before Porpoise quit, not in \(entry.provider.title) yet.") }
                self.add(entry, binding: binding); self.watch(entry.id)
            }
            self.retryUnsent()
        }
    }
    public func dismiss(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), entry.mark == .editing || entry.mark == .saved else { return }
        watchers.removeValue(forKey: id)?.cancel()
        if let binding = bindings.removeValue(forKey: id) { Task { await binding.release(id) } }
        entries.removeAll { $0.id == id }; changed()
    }
}

// Source-compatible names share this one coordinator; there are no provider-specific editing flows.
public typealias CloudEditing = CloudEditCoordinator
public typealias DriveEditing = CloudEditCoordinator
public typealias DropboxEditing = CloudEditCoordinator
