import Foundation
import PorpoiseCore

/// Opens a remote file: downloads it to a cache, opens it, and uploads it again when the app saves changes
/// (KIO does the same for remote files opened in local applications).
public enum RemoteOpener {
    /// Opens a downloaded copy in its application (set by the app).
    nonisolated(unsafe) public static var openFile: (URL) -> Void = { _ in }

    /// Only on the main queue.
    nonisolated(unsafe) private static var watchers: [String: DispatchSourceFileSystemObject] = [:]
    /// Local copies with saved changes not yet uploaded (the upload failed or hasn't run): only on the main queue.
    nonisolated(unsafe) private static var unsynced: Set<String> = []

    /// Upload is delayed this long after the last change, so a burst of writes from one save uploads once.
    private static let uploadDelay: TimeInterval = 0.6
    /// Runs the watch of a file that replaced the one watched, on the main queue (a test holds it back, as a busy
    /// main queue would).
    nonisolated(unsafe) static var rewatchOnMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// Uploads run one at a time, so an older save can never land on the server after a newer one.
    private static let uploadQueue = DispatchQueue(label: "porpoise.remote-upload")

    /// Mirror of the remote folder inside the cache. "." and ".." components are dropped so a crafted
    /// URL (sftp://host/../../x) can't point outside the cache: the file there is replaced on download.
    static func cacheFolder(for remote: URL) -> URL {
        var folder = RemoteFS.cacheRoot.appendingPathComponent(remote.scheme ?? "x").appendingPathComponent(remote.host ?? "h")
        for c in remote.deletingLastPathComponent().pathComponents where RemoteParsing.isSafeName(c) {
            folder.appendPathComponent(c)
        }
        return folder
    }

    public static func open(_ item: FileItem) {
        guard let p = RemoteFS.provider(for: item.url), RemoteParsing.isSafeName(item.url.lastPathComponent) else { return }
        let folder = cacheFolder(for: item.url)
        let cached = folder.appendingPathComponent(item.url.lastPathComponent)
        // Opened again before its edits reached the server: open those edits, never replace them with a download.
        if unsynced.contains(cached.path), FileManager.default.fileExists(atPath: cached.path) {
            openFile(cached)
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
                    openFile(got)
                    watch(got, remote: item.url, provider: p)
                    StatusCenter.post("Opened “\(item.name)”. Saved changes are uploaded back automatically.")
                }
            } catch {
                DispatchQueue.main.async { StatusCenter.error("Could not open “\(item.name)”: \(error.localizedDescription)") }
            }
        }
    }

    /// `uploading`: the file (inode) an upload is about to read; if another file has replaced it by the time the
    /// watch starts, that save would go unnoticed, so it's uploaded too.
    private static func watch(_ local: URL, remote: URL, provider: RemoteProvider, uploading: ino_t? = nil) {
        watchers[local.path]?.cancel()
        let fd = Darwin.open(local.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // One serial queue for the source's events and the catch-up below, so `pending` is only touched there.
        let events = DispatchQueue(label: "porpoise.remote-watch")
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: events)
        var pending: DispatchWorkItem?
        func changed(replaced: Bool) {
            DispatchQueue.main.async { unsynced.insert(local.path) }
            pending?.cancel()
            let work = DispatchWorkItem {
                guard FileManager.default.fileExists(atPath: local.path) else {
                    // Deleted for good: nothing left to upload (unless the file was opened again meanwhile).
                    DispatchQueue.main.async { if watchers[local.path] === src { unwatch(local) } }
                    return
                }
                // Editors often save by replacing the file: watch the new one before uploading, so a
                // save made while the upload runs is not missed.
                if replaced {
                    let file = inode(of: local.path)
                    rewatchOnMain { watch(local, remote: remote, provider: provider, uploading: file) }
                }
                var failure: Error?
                do { try provider.upload(local, into: remote.deletingLastPathComponent()) } catch { failure = error }
                DispatchQueue.main.async {
                    if let e = failure {
                        StatusCenter.error("Could not upload “\(remote.lastPathComponent)”: \(e.localizedDescription)")
                    } else {
                        unsynced.remove(local.path)
                        StatusCenter.post("Uploaded changes to “\(remote.lastPathComponent)”.")
                        FileOperationsController.notifyChanged([remote])
                    }
                }
            }
            pending = work
            uploadQueue.asyncAfter(deadline: .now() + uploadDelay, execute: work)
        }
        src.setEventHandler { changed(replaced: src.data.contains(.rename) || src.data.contains(.delete)) }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers[local.path] = src
        var st = stat()
        if let uploading, fstat(fd, &st) == 0, st.st_ino != uploading { events.async { changed(replaced: false) } }
    }

    private static func inode(of path: String) -> ino_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_ino : nil
    }

    private static func unwatch(_ local: URL) {
        watchers.removeValue(forKey: local.path)?.cancel()
    }
}
