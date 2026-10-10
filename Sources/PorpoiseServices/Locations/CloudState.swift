import Foundation
import PorpoiseCore

/// iCloud Drive / File Provider (Google Drive, OneDrive, Dropbox…) state of an item, as Finder shows it.
public enum CloudState: Equatable {
    case local          // not a cloud item, or downloaded and in sync (no badge, like Finder)
    case cloudOnly      // only in the cloud: Finder's cloud-with-arrow
    case downloading
    case uploading

    private static let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                    .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey]

    static func of(_ url: URL) -> (state: CloudState, isCloud: Bool) {
        guard url.isFileURL, let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else { return (.local, false) }
        if v.ubiquitousItemIsDownloading == true { return (.downloading, true) }
        if v.ubiquitousItemIsUploading == true { return (.uploading, true) }
        if v.ubiquitousItemDownloadingStatus == .notDownloaded { return (.cloudOnly, true) }
        return (.local, true)
    }

    public var symbol: String? {
        switch self {
        case .local: return nil
        case .cloudOnly: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle.dotted"
        case .uploading: return "icloud.and.arrow.up"
        }
    }

    public var help: String {
        switch self {
        case .local: return ""
        case .cloudOnly: return "In the cloud only. Click to download."
        case .downloading: return "Downloading…"
        case .uploading: return "Uploading…"
        }
    }
}

public enum CloudActions {
    /// Download Now: files directly, folders with everything inside.
    public static func download(_ urls: [URL]) {
        let fm = FileManager.default
        DispatchQueue.global(qos: .userInitiated).async {
            for u in urls {
                try? fm.startDownloadingUbiquitousItem(at: u)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
                   let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isUbiquitousItemKey], options: []) {
                    for case let c as URL in e { try? fm.startDownloadingUbiquitousItem(at: c) }
                }
            }
            DispatchQueue.main.async { FileOperationsController.notifyChanged(urls) }
        }
    }

    /// Remove Download: keeps the item in the cloud, frees the local copy. Returns what failed, as messages.
    public static func evict(_ urls: [URL]) -> [String] {
        var failed: [String] = []
        for u in urls {
            do { try FileManager.default.evictUbiquitousItem(at: u) } catch { failed.append("“\(u.lastPathComponent)”: \(error.localizedDescription)") }
        }
        FileOperationsController.notifyChanged(urls)
        return failed
    }
}
