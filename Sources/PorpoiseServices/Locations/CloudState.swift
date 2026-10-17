import Foundation
import PorpoiseCore

/// iCloud Drive / File Provider (Google Drive, OneDrive, Dropbox…) state of an item, as Finder shows it; for the
/// accounts Porpoise connects to, also whether it is kept downloaded.
public enum CloudState: Equatable {
    case local  // not a cloud item, or downloaded and not kept (no badge, like Finder)
    case cloudOnly  // only in the cloud: Finder's cloud-with-arrow
    /// 0…1, nil when not known.
    case downloading(Double?)
    /// Keep Downloaded: on this Mac and kept current.
    case kept
    case uploading(Double?)
    /// Couldn't be downloaded or kept (the reason, for the tooltip).
    case error(String)

    private static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey,
    ]

    static func of(_ url: URL) -> (state: CloudState, isCloud: Bool) {
        guard url.isFileURL, let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else { return (.local, false) }
        if v.ubiquitousItemIsDownloading == true { return (.downloading(nil), true) }
        if v.ubiquitousItemIsUploading == true { return (.uploading(nil), true) }
        if v.ubiquitousItemDownloadingStatus == .notDownloaded { return (.cloudOnly, true) }
        return (.local, true)
    }

    /// Downloading or uploading: the badge is refreshed while it lasts.
    public var isTransferring: Bool {
        switch self {
        case .downloading, .uploading: return true
        default: return false
        }
    }

    /// How far a transfer has come (nil: not transferring, or not known).
    public var progress: Double? {
        switch self {
        case .downloading(let p), .uploading(let p): return p
        default: return nil
        }
    }

    public var symbol: String? {
        switch self {
        case .local: return nil
        case .cloudOnly: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle.dotted"
        case .kept: return "arrow.down.circle.fill"
        case .uploading: return "icloud.and.arrow.up"
        case .error: return "exclamationmark.icloud"
        }
    }

    public var help: String {
        switch self {
        case .local: return ""
        case .cloudOnly: return "In the cloud only. Click to download."
        case .downloading(let p): return p.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…"
        case .kept: return "Kept downloaded on this Mac."
        case .uploading(let p): return p.map { "Uploading… \(Int($0 * 100))%" } ?? "Uploading…"
        case .error(let why): return why
        }
    }
}

/// The one badge an item's icon shows: an edit in progress comes first, then problems, transfers, kept, cloud-only.
public enum CloudBadgeKind: Equatable {
    case none
    case edit(CloudEditMark)
    case cloud(CloudState)

    public static func resolve(_ state: CloudState, edit: CloudEditMark?) -> CloudBadgeKind {
        if let edit { return .edit(edit) }
        return state == .local ? .none : .cloud(state)
    }

    /// The cloud state drawn, if any.
    public var cloudState: CloudState? {
        if case .cloud(let s) = self { return s }
        return nil
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
                    let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isUbiquitousItemKey], options: [])
                {
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
            do { try FileManager.default.evictUbiquitousItem(at: u) } catch {
                failed.append("“\(u.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        FileOperationsController.notifyChanged(urls)
        return failed
    }
}
