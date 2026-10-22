import Foundation
import PorpoiseCore

/// Cloud files use their established editing flow. Other remote files live in durable local sessions; save-back
/// is enabled only when the provider can conditionally publish an immutable snapshot.
@MainActor public enum RemoteOpener {
    /// Opens a downloaded copy in its application (set by the app).
    nonisolated(unsafe) public static var openFile: (URL) -> Void = { _ in }

    /// Only on the main queue.
    private static var watchers: [String: SaveWatcher] = [:]
    private static var stores: [String: RemoteEditSessionStore] = [:]
    private static var opening: [String: [(URL) -> Void]] = [:]
    private static var saving: Set<String> = []
    private static var saveAgain: Set<String> = []

    /// Upload is delayed this long after the last change, so a burst of writes from one save uploads once.
    private static let uploadDelay: TimeInterval = 0.6
    /// Runs the watch of a file that replaced the one watched, on the main queue (a test holds it back, as a busy
    /// main queue would).
    nonisolated(unsafe) static var rewatchOnMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// Legacy/cache-copy callers still get account/port-separated paths. Editable bytes use Application Support.
    nonisolated static func cacheFolder(for remote: URL) -> URL {
        RemoteFS.cacheRoot.appendingPathComponent(RemoteEditSessionStore.identity(remote.deletingLastPathComponent()))
    }

    private static var sessionRoot: URL {
        (RemoteFS.cacheParentOverride ?? Settings.supportFolder).appendingPathComponent("Remote Edits", isDirectory: true)
    }

    /// Some bridge and service callbacks are synchronous and not actor-annotated. Marshal them before touching state.
    nonisolated public static func open(_ item: FileItem, using launch: ((URL) -> Void)? = nil) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { openOnMain(item, using: launch) }
        } else {
            DispatchQueue.main.async { openOnMain(item, using: launch) }
        }
    }

    private static func openOnMain(_ item: FileItem, using launch: ((URL) -> Void)?) {
        let launch = launch ?? openFile
        guard let p = RemoteFS.provider(for: item.url), RemoteParsing.isSafeName(item.url.lastPathComponent) else { return }
        if item.url.scheme == "archive" {
            Task { @MainActor in
                do {
                    let local = try await CloudRemoteOpen.prepare(item) { try await ArchiveBrowser.localCopy(item.url, context: $0) }
                    launch(local)
                    StatusCenter.post("Opened a copy of “\(item.name)”. Changes stay on this Mac.")
                } catch {
                    if !(error is CancellationError) { StatusCenter.error("Could not open “\(item.name)”: \(error.localizedDescription)") }
                }
            }
            return
        }
        if PlacesModel.isCloud(item.url) {
            // A file the account may change: edited in place, its saves go back to Drive as new versions.
            if CloudEditing.shared.canEdit(item) {
                CloudEditing.shared.open(item, using: launch) { opened in if !opened { openCopy(item, provider: p, launch: launch) } }
                return
            }
            openCopy(item, provider: p, launch: launch)
            return
        }
        let candidate = RemoteEditSessionStore(remote: item.url, root: sessionRoot)
        let key = candidate.folder.path
        if opening[key] != nil { opening[key]?.append(launch); return }
        opening[key] = [launch]
        let store = stores[key] ?? candidate
        stores[key] = store
        Task { @MainActor in
            do {
                let local = try await CloudRemoteOpen.prepare(item) { context in try await store.open(provider: p, context: context) }
                let launches = opening.removeValue(forKey: key) ?? []
                if p is RemoteEditPublishing {
                    watch(store, remote: item.url, provider: p)
                    StatusCenter.post("Opened “\(item.name)”. Saved changes are uploaded only if the server version is unchanged.")
                } else {
                    StatusCenter.post(
                        "Opened a copy of “\(item.name)”. Changes stay on this Mac; this server cannot safely save them back automatically.")
                }
                for launch in launches { launch(local) }
            } catch {
                opening.removeValue(forKey: key)
                if !(error is CancellationError) {
                    StatusCenter.error("Could not open “\(item.name)”: \(error.localizedDescription)")
                }
            }
        }
    }

    /// A copy that stays on this Mac (read-only items, Google Docs' exports): never sent back.
    private static func openCopy(_ item: FileItem, provider p: RemoteProvider, launch: @escaping (URL) -> Void) {
        if let drive = p as? CloudFileProvider {
            Task { @MainActor in
                do { launch(try await drive.preview(item.url)) } catch {
                    if !(error is CancellationError) { StatusCenter.error("Could not open “\(item.name)”: \(error.localizedDescription)") }
                }
            }
            return
        }
        let folder = cacheFolder(for: item.url).appendingPathComponent(item.url.lastPathComponent).appendingPathComponent(UUID().uuidString)
        StatusCenter.post("Downloading “\(item.name)”…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let local = try p.download(item.url, into: folder)
                DispatchQueue.main.async {
                    launch(local)
                    StatusCenter.post("Opened a copy of “\(item.name)”. Changes stay on this Mac.")
                }
            } catch {
                DispatchQueue.main.async { StatusCenter.error("Could not open “\(item.name)”: \(error.localizedDescription)") }
            }
        }
    }

    private static func watch(_ store: RemoteEditSessionStore, remote: URL, provider: RemoteProvider) {
        let key = store.folder.path
        guard watchers[key] == nil else { return }
        watchers[key] = SaveWatcher(store.local, delay: uploadDelay, queue: .main, reattach: { rewatchOnMain($0) }) {
            save(store, remote: remote, provider: provider)
        }
    }

    private static func save(_ store: RemoteEditSessionStore, remote: URL, provider: RemoteProvider) {
        let key = store.folder.path
        guard saving.insert(key).inserted else { saveAgain.insert(key); return }
        Task { @MainActor in
            do {
                var dirty = false
                _ = try await FileOperationsController.shared.cloudTask(title: "Saving “\(remote.lastPathComponent)”", sources: [remote]) { context in
                    dirty = try await store.save(provider: provider, context: context)
                    return [store.local]
                }
                if dirty { saveAgain.insert(key) }
                StatusCenter.post("Uploaded changes to “\(remote.lastPathComponent)”.")
                FileOperationsController.notifyChanged([remote])
                saving.remove(key)
                if saveAgain.remove(key) != nil { save(store, remote: remote, provider: provider) }
            } catch {
                saving.remove(key); saveAgain.remove(key)
                if !(error is CancellationError) {
                    StatusCenter.error(
                        "Could not upload “\(remote.lastPathComponent)”: \(error.localizedDescription) Your changes are kept on this Mac.")
                }
            }
        }
    }
}
