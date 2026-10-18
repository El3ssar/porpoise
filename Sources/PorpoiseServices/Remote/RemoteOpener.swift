import Foundation
import PorpoiseCore

/// Opens a remote file: downloads it to a cache, opens it, and uploads it again when the app saves changes
/// (KIO does the same for remote files opened in local applications).
public enum RemoteOpener {
    /// Opens a downloaded copy in its application (set by the app).
    nonisolated(unsafe) public static var openFile: (URL) -> Void = { _ in }

    /// Only on the main queue.
    nonisolated(unsafe) private static var watchers: [String: SaveWatcher] = [:]
    /// Local copies with saved changes not yet uploaded (the upload failed or hasn't run): only on the main queue.
    nonisolated(unsafe) private static var unsynced: Set<String> = []

    /// Upload is delayed this long after the last change, so a burst of writes from one save uploads once.
    private static let uploadDelay: TimeInterval = 0.6
    /// Runs the watch of a file that replaced the one watched, on the main queue (a test holds it back, as a busy
    /// main queue would).
    nonisolated(unsafe) static var rewatchOnMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// Uploads run one at a time, so an older save can never land on the server after a newer one.
    private static let uploadQueue = DispatchQueue(label: "porpoise.remote-upload", autoreleaseFrequency: .workItem)

    /// Mirror of the remote folder inside the cache. "." and ".." components are dropped so a crafted
    /// URL (sftp://host/../../x) can't point outside the cache: the file there is replaced on download.
    static func cacheFolder(for remote: URL) -> URL {
        var folder = RemoteFS.cacheRoot.appendingPathComponent(remote.scheme ?? "x").appendingPathComponent(remote.host ?? "h")
        if let location = S3Location(url: remote) {
            let identity = "\(location.accountID)|\(location.endpoint)|\(location.region)"
            folder.appendPathComponent(S3Signer.hash(Data(identity.utf8)))
        }
        for c in remote.deletingLastPathComponent().pathComponents where RemoteParsing.isSafeName(c) {
            folder.appendPathComponent(c)
        }
        return folder
    }

    public static func open(_ item: FileItem, using launch: ((URL) -> Void)? = nil) {
        let launch = launch ?? openFile
        guard let p = RemoteFS.provider(for: item.url), RemoteParsing.isSafeName(item.url.lastPathComponent) else { return }
        if PlacesModel.isCloud(item.url) {
            // A file the account may change: edited in place, its saves go back to Drive as new versions.
            if CloudEditing.shared.canEdit(item) {
                CloudEditing.shared.open(item, using: launch) { opened in if !opened { openCopy(item, provider: p, launch: launch) } }
                return
            }
            openCopy(item, provider: p, launch: launch)
            return
        }
        let folder = cacheFolder(for: item.url)
        let cached = folder.appendingPathComponent(item.url.lastPathComponent)
        // Opened again before its edits reached the server: open those edits, never replace them with a download.
        if unsynced.contains(cached.path), FileManager.default.fileExists(atPath: cached.path) {
            launch(cached)
            StatusCenter.post("Opened your copy of “\(item.name)”: its latest changes haven't been uploaded yet.")
            return
        }
        // The copy from an earlier open is deleted below: its watch would take that for a save, mark the copy as not
        // uploaded (and, once the download is in place, upload it straight back).
        unwatch(cached)
        StatusCenter.post("Downloading “\(item.name)”…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let local = folder.appendingPathComponent(item.url.lastPathComponent)
                try? FileManager.default.removeItem(at: local)
                let got = try p.download(item.url, into: folder)
                DispatchQueue.main.async {
                    launch(got)
                    watch(got, remote: item.url, provider: p)
                    StatusCenter.post("Opened “\(item.name)”. Saved changes are uploaded back automatically.")
                }
            } catch {
                DispatchQueue.main.async { StatusCenter.error("Could not open “\(item.name)”: \(error.localizedDescription)") }
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

    private static func watch(_ local: URL, remote: URL, provider: RemoteProvider) {
        watchers[local.path]?.cancel()
        watchers[local.path] = SaveWatcher(
            local, delay: uploadDelay, queue: uploadQueue,
            reattach: { rewatchOnMain($0) }, changed: { DispatchQueue.main.async { unsynced.insert(local.path) } }
        ) {
            var failure: Error?
            do { try provider.upload(local, into: remote.deletingLastPathComponent()) } catch { failure = error }
            DispatchQueue.main.async {
                if let error = failure {
                    StatusCenter.error("Could not upload “\(remote.lastPathComponent)”: \(error.localizedDescription)")
                } else {
                    unsynced.remove(local.path)
                    StatusCenter.post("Uploaded changes to “\(remote.lastPathComponent)”.")
                    FileOperationsController.notifyChanged([remote])
                }
            }
        }
    }

    private static func unwatch(_ local: URL) {
        watchers.removeValue(forKey: local.path)?.cancel()
    }
}
