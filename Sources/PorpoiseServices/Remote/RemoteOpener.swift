import Foundation
import PorpoiseCore

/// Editable cloud files use their established conditional save-back flow; other opens launch independent read-only copies.
@MainActor public enum RemoteOpener {
    /// Opens a downloaded copy in its application (set by the app).
    nonisolated(unsafe) public static var openFile: (URL) -> Void = { _ in }

    /// Only on the main queue.
    private static var stores: [String: RemoteOpenCopyStore] = [:]
    private static var storeOrder: [String] = []
    private static var opening: [String: [(URL) -> Void]] = [:]
    /// Legacy/cache-copy callers still get account/port-separated paths. Editable bytes use Application Support.
    nonisolated static func cacheFolder(for remote: URL) -> URL {
        RemoteFS.cacheRoot.appendingPathComponent(RemoteOpenCopyStore.identity(remote.deletingLastPathComponent()))
    }

    private static var sessionRoot: URL {
        (RemoteFS.cacheParentOverride ?? Settings.supportFolder).appendingPathComponent("Remote Copies", isDirectory: true)
    }

    /// Called after the first window has rendered; no cleanup filesystem work runs on the main actor.
    public static func sweepStaleCopiesAfterLaunch() {
        guard !Settings.isTesting else { return }
        let roots = Set([sessionRoot] + RemoteFS.openCopyRoots)
        DispatchQueue.global(qos: .utility).async {
            for root in roots { try? RemoteOpenCopyStore.sweepRoot(root) }
        }
    }
    private static func cachedStore(_ candidate: RemoteOpenCopyStore) -> RemoteOpenCopyStore {
        let key = candidate.folder.path, store = stores[key] ?? candidate
        stores[key] = store
        storeOrder.removeAll { $0 == key }; storeOrder.append(key)
        while storeOrder.count > 128 { stores[storeOrder.removeFirst()] = nil }
        return store
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
        let candidate = RemoteOpenCopyStore(remote: item.url, root: sessionRoot)
        let key = candidate.folder.path
        if opening[key] != nil { opening[key]?.append(launch); return }
        opening[key] = [launch]
        let store = cachedStore(candidate)
        Task { @MainActor in
            do {
                let local = try await CloudRemoteOpen.prepare(item) { context in try await store.open(provider: p, context: context) }
                let launches = opening.removeValue(forKey: key) ?? []
                StatusCenter.post("Opened a read-only copy of “\(item.name)”. Changes are not saved to the server.")
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
                do {
                    let source = try await drive.preview(item.url)
                    guard let root = (drive as? any CloudOpenCopyOwning)?.openCopyDirectory else { throw CloudContentError.unsupported }
                    let candidate = RemoteOpenCopyStore(remote: item.url, root: root)
                    let store = cachedStore(candidate)
                    launch(try await store.copy(source))
                    StatusCenter.post("Opened a read-only copy of “\(item.name)”. Changes are not saved to the server.")
                } catch {
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

}
