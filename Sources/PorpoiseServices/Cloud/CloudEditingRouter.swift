import Foundation
import PorpoiseCore

/// Editing marks and Activity actions are capabilities; views never choose an account's implementation.
public final class CloudEditing {
    public static let shared = CloudEditing()
    public static let changed = Notification.Name("PorpoiseCloudEditingChanged")
    private var watch: NSObjectProtocol?
    private init() {
        watch = NotificationCenter.default.addObserver(forName: DriveEditing.changed, object: nil, queue: .main) { _ in
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
    public var entries: [CloudEditEntry] { DriveEditing.shared.entries + DropboxEditing.shared.entries }
    public var openFile: (URL) -> Void {
        get { DriveEditing.shared.openFile }
        set { DriveEditing.shared.openFile = newValue; DropboxEditing.shared.openFile = newValue }
    }
    public var post: (String, Bool) -> Void {
        get { DriveEditing.shared.post }
        set { DriveEditing.shared.post = newValue; DropboxEditing.shared.post = newValue }
    }
    public var restoresAtLaunch: Bool {
        get { DriveEditing.shared.restoresAtLaunch }
        set { DriveEditing.shared.restoresAtLaunch = newValue }
    }
    public func entry(for url: URL) -> CloudEditEntry? {
        DriveEditing.shared.entry(for: url) ?? DropboxEditing.shared.entries.first { $0.location == url }
    }
    public func mark(for url: URL) -> CloudEditMark? { entry(for: url)?.mark }
    public func canEdit(_ item: FileItem) -> Bool { DriveEditing.shared.canEdit(item) || DropboxEditing.shared.canEdit(item) }
    public func open(_ item: FileItem, using launch: ((URL) -> Void)? = nil, done: @escaping (Bool) -> Void = { _ in }) {
        if DriveEditing.shared.canEdit(item) {
            DriveEditing.shared.open(item, using: launch, done: done)
        } else {
            DropboxEditing.shared.open(item, using: launch ?? openFile, done: done)
        }
    }
    public func save(_ id: UUID) { if DropboxEditing.shared.contains(id) { DropboxEditing.shared.save(id) } else { DriveEditing.shared.save(id) } }
    public func keepBoth(_ id: UUID) {
        if DropboxEditing.shared.contains(id) { DropboxEditing.shared.keepBoth(id) } else { DriveEditing.shared.keepBoth(id) }
    }
    public func replaceWithMine(_ id: UUID) {
        if DropboxEditing.shared.contains(id) { DropboxEditing.shared.replace(id) } else { DriveEditing.shared.replaceWithMine(id) }
    }
    public func openBoth(_ id: UUID) {
        if DropboxEditing.shared.contains(id) { DropboxEditing.shared.openBoth(id) } else { DriveEditing.shared.openBoth(id) }
    }
    public func dismiss(_ id: UUID) {
        if DropboxEditing.shared.contains(id) { DropboxEditing.shared.dismiss(id) } else { DriveEditing.shared.dismiss(id) }
    }
}

/// Durable Dropbox edits use the same marks and Activity rows as other cloud providers.
public final class DropboxEditing {
    public static let shared = DropboxEditing()
    public var openFile: (URL) -> Void = { _ in }
    public var post: (String, Bool) -> Void = { _, _ in }
    public var saveDelay: TimeInterval = 0.8
    public private(set) var entries: [CloudEditEntry] = []
    private var clients: [UUID: DropboxClient] = [:]
    private var watches: [UUID: DispatchSourceFileSystemObject] = [:]
    private var pending: [UUID: DispatchWorkItem] = [:]
    private var saving: Set<UUID> = []
    deinit { for watch in watches.values { watch.cancel() }; for work in pending.values { work.cancel() } }
    public func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }
    public func canEdit(_ item: FileItem) -> Bool {
        guard !item.isBrowsableFolder, let provider = RemoteFS.provider(for: item.url) as? DropboxProvider,
            let file = provider.metadata(item.url)
        else { return false }
        return file.rev != nil && file.isDownloadable != false && CloudAccounts.shared.accountDenial(for: item.url) == nil
    }
    public func restore(_ client: DropboxClient) {
        Task { @MainActor in
            for session in await client.edits.pending() where !contains(session.id) {
                add(session, client: client, mark: .unsent("Saved changes haven’t reached Dropbox."))
            }
        }
    }
    public func open(_ item: FileItem, using launch: @escaping (URL) -> Void, done: @escaping (Bool) -> Void) {
        guard let provider = RemoteFS.provider(for: item.url) as? DropboxProvider else { done(false); return }
        Task { @MainActor in
            do {
                let client = try provider.scoped(item.url)
                let file = try await client.metadata(provider.location(item.url).itemID)
                let session = try await client.edits.begin(file)
                add(session, client: client, mark: .editing); watch(session.id); launch(session.localURL); done(true)
            } catch { post(error.localizedDescription, true); done(false) }
        }
    }
    private func add(_ session: DropboxEditStore.Session, client: DropboxClient, mark: CloudEditMark) {
        clients[session.id] = client
        let entry = CloudEditEntry(
            id: session.id, account: client.accountID, fileID: session.file.id, name: session.file.name,
            localURL: session.localURL, mark: mark,
            location: DropboxLocation(accountID: client.accountID, itemID: session.file.id, namespaceID: client.namespaceID).url, provider: .dropbox)
        if let index = entries.firstIndex(where: { $0.id == session.id }) { entries[index] = entry } else { entries.append(entry) }
        changed()
    }
    private func changed() { NotificationCenter.default.post(name: CloudEditing.changed, object: nil) }
    private func mark(_ id: UUID, _ mark: CloudEditMark) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].mark = mark; changed() }
    }
    private func watch(_ id: UUID) {
        watches.removeValue(forKey: id)?.cancel()
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let fd = Darwin.open(entry.localURL.path, O_EVTONLY); guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watches[id]?.data.contains(.rename) == true || self.watches[id]?.data.contains(.delete) == true {
                // Atomic editor saves replace the inode. Wait for the replacement without blocking the main queue.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.watch(id) }
            }
            self.pending.removeValue(forKey: id)?.cancel()
            self.mark(id, .unsent("Waiting to send saved changes."))
            let work = DispatchWorkItem { [weak self] in self?.save(id) }; self.pending[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.saveDelay, execute: work)
        }
        watches[id] = source; source.resume()
    }
    public func save(_ id: UUID) {
        guard let client = clients[id], saving.insert(id).inserted else { return }
        mark(id, .saving)
        Task { @MainActor in
            defer { saving.remove(id) }
            do {
                let session = try await client.edits.save(id)
                mark(id, session.state == "unsent" ? .unsent("New changes are waiting to send.") : .saved)
                watch(id)
                if session.state == "unsent" {
                    DispatchQueue.main.async { [weak self = self] in self?.save(id) }
                }
            } catch {
                mark(id, (error as? DropboxError) == .conflict ? .conflict : .unsent(error.localizedDescription));
                post(error.localizedDescription, true)
            }
        }
    }
    public func keepBoth(_ id: UUID) {
        guard let client = clients[id], saving.insert(id).inserted else { return }
        Task { @MainActor in
            defer { saving.remove(id) }
            do {
                guard let session = await client.edits.session(id) else { return }
                let parent = session.file.parentPath; let files = try await client.list(parent)
                let name = FileFormat.suggestedName(for: session.file.name, existing: Set(files.map(\.name)))
                let path = try DropboxClient.childPath(name: name, parent: parent)
                let result = try await client.edits.saveAsCopy(id, to: path); add(result, client: client, mark: .saved); watch(id)
            } catch { mark(id, .unsent(error.localizedDescription)); post(error.localizedDescription, true) }
        }
    }
    public func replace(_ id: UUID) {
        guard let client = clients[id], saving.insert(id).inserted else { return }
        Task { @MainActor in
            defer { saving.remove(id) }
            do {
                guard let session = await client.edits.session(id) else { return }
                let current = try await client.metadata(session.file.id)
                let result = try await client.edits.replace(id, expectedCurrent: current)
                add(result, client: client, mark: .saved); watch(id)
            } catch { mark(id, (error as? DropboxError) == .conflict ? .conflict : .unsent(error.localizedDescription)) }
        }
    }
    public func openBoth(_ id: UUID) {
        guard let client = clients[id], let entry = entries.first(where: { $0.id == id }) else { return }
        openFile(entry.localURL)
        Task { @MainActor in
            do { let file = try await client.metadata(entry.fileID); openFile(try await client.open(file)) } catch {
                post(error.localizedDescription, true)
            }
        }
    }
    public func dismiss(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), !entry.mark.needsAttention else { return }
        watches.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.cancel()
        if let client = clients.removeValue(forKey: id) { Task { await client.edits.release(id) } }
        entries.removeAll { $0.id == id }; changed()
    }
}
