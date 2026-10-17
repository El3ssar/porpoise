import Foundation
import PorpoiseCore

/// Finder's cloud commands for a selection (Download Now, Keep Downloaded, Remove Download), for iCloud Drive and File
/// Provider items as well as the accounts Porpoise connects to: which ones the menus offer, and doing them.
public enum CloudCommands {
    public enum Check: Equatable { case off, on, mixed }

    /// What the menus show for a selection.
    public struct Available: Equatable {
        public var downloadNow = false
        /// Keep Downloaded: nil when not offered (iCloud, virtual rows).
        public var keep: Check?
        public var keepEnabled = true
        public var removeDownload = false
        public var removeEnabled = true
        /// Why Keep Downloaded or Remove Download is disabled.
        public var reason: String?

        public init(
            downloadNow: Bool = false, keep: Check? = nil, keepEnabled: Bool = true, removeDownload: Bool = false, removeEnabled: Bool = true,
            reason: String? = nil
        ) {
            self.downloadNow = downloadNow
            self.keep = keep
            self.keepEnabled = keepEnabled
            self.removeDownload = removeDownload
            self.removeEnabled = removeEnabled
            self.reason = reason
        }

        public var isEmpty: Bool { !downloadNow && keep == nil && !removeDownload }
    }

    /// The offline service (tests hand theirs).
    public static var service: () -> CloudOfflineService? = { CloudOfflineHub.service }

    static func isAccountItem(_ url: URL) -> Bool {
        !url.isFileURL && service()?.supports(url) == true
    }

    /// `cloud`: an item's state as the view knows it (DirectoryModel.cloud(for:)).
    public static func available(for items: [FileItem], cloud: (FileItem) -> (state: CloudState, isCloud: Bool)) -> Available {
        let accountItems = items.filter { isAccountItem($0.url) }
        if accountItems.isEmpty { return iCloud(items.filter(\.url.isFileURL), cloud: cloud) }
        guard let service = service() else { return Available() }
        var a = Available()
        a.downloadNow = accountItems.contains { $0.isBrowsableFolder || cloud($0).state == .cloudOnly }
        let keeps = accountItems.map { service.keep(for: $0.url) }
        let kept = keeps.filter { $0 != .no }.count
        a.keep = kept == 0 ? .off : kept == keeps.count ? .on : .mixed
        a.removeDownload = accountItems.contains { service.hasLocalCopy($0.url) || service.keep(for: $0.url) != .no }
        // Kept because a folder above is: only that folder can stop it.
        if case .inherited(let folder) = keeps.first, keeps.allSatisfy({ if case .inherited = $0 { return true } else { return false } }) {
            a.keepEnabled = false
            a.removeEnabled = false
            a.reason = "Kept because “\(folder)” is kept downloaded."
        }
        if let why = accountItems.lazy.compactMap({ service.keepDenial(for: $0.url) }).first {
            a.keepEnabled = false
            a.downloadNow = false
            a.reason = why
        }
        return a
    }

    /// iCloud Drive and File Provider items: Download Now and Remove Download, as before.
    private static func iCloud(_ items: [FileItem], cloud: (FileItem) -> (state: CloudState, isCloud: Bool)) -> Available {
        let clouds = items.map(cloud)
        guard clouds.contains(where: { $0.isCloud }) else { return Available() }
        var a = Available()
        a.downloadNow = clouds.contains { $0.state == .cloudOnly } || items.contains(where: \.isBrowsableFolder)
        a.removeDownload = clouds.contains { $0.isCloud && $0.state != .cloudOnly }
        return a
    }

    // MARK: Doing them

    public static func downloadNow(_ urls: [URL]) {
        let local = urls.filter(\.isFileURL)
        if !local.isEmpty { CloudActions.download(local) }
        let remote = urls.filter(isAccountItem)
        if !remote.isEmpty { service()?.downloadNow(remote) }
    }

    /// Choosing Keep Downloaded: stops keeping when every item is kept, else asks for a plan to keep them (the app
    /// confirms big ones). Returns true when it started a plan (`planned` answers).
    public static func stopKeepingIfAllKept(_ urls: [URL]) -> Bool {
        guard let service = service() else { return false }
        let remote = urls.filter(isAccountItem)
        guard !remote.isEmpty, remote.allSatisfy({ service.keep(for: $0) != .no }) else { return false }
        service.stopKeeping(remote.filter { service.keep(for: $0) == .direct })
        return true
    }

    /// Remove Download: returns a message for each item that couldn't be removed.
    public static func removeDownload(_ urls: [URL]) -> [String] {
        var failed: [String] = []
        let local = urls.filter(\.isFileURL)
        if !local.isEmpty { failed += CloudActions.evict(local) }
        let remote = urls.filter(isAccountItem)
        if !remote.isEmpty, let service = service() { failed += service.removeDownload(remote) }
        return failed
    }

    // MARK: Words

    /// "12.4 GB in 3,210 items. You have 48 GB available on this Mac."
    public static func planText(_ plan: CloudKeepPlan, folder: Bool) -> String {
        let items = plan.items == 1 ? "1 item" : "\(plan.items.formatted()) items"
        let what = "\(FileFormat.size(plan.bytes)) in \(items)."
        guard plan.fits else { return "Needs \(FileFormat.size(plan.bytes)); you have \(FileFormat.size(max(0, plan.available))) available." }
        let more = folder ? " New items added to this folder will download too." : ""
        return "\(what) You have \(FileFormat.size(plan.available)) available on this Mac.\(more)"
    }

    /// Settings' choices for recently opened files (nil: no limit).
    public static let cacheLimits: [(title: String, bytes: Int64?)] = [
        ("1 GB", 1 << 30), ("5 GB", 5 << 30), ("10 GB", 10 << 30), ("25 GB", 25 << 30), ("No limit", nil),
    ]

    /// "Google Drive · me@x: kept 3.1 GB · recent 820 MB".
    public static func usageText(_ u: CloudOfflineUsage, account: String) -> String {
        "\(account): kept \(FileFormat.size(u.kept)) · recent \(FileFormat.size(u.recent))"
    }

    /// The line the sign-out confirmation adds when the account has copies on this Mac.
    public static func signOutLine(bytes: Int64, provider: String) -> String? {
        guard bytes > 0 else { return nil }
        return "The \(FileFormat.size(bytes)) of offline copies on this Mac will be deleted. Your files stay in \(provider)."
    }

    /// Properties' "On this Mac" row.
    public static func summaryText(_ d: CloudOfflineDetails, folder: Bool, provider: String) -> String {
        if let why = d.error { return why }
        if let p = d.progress { return "Downloading \(Int(p * 100)) %" }
        let keep = CloudKeep(d)
        if folder {
            guard d.totalItems > 0 else { return keep == .no ? "In \(provider) only" : "Kept downloaded" }
            let bytes =
                d.totalBytes > 0
                ? "\(FileFormat.size(d.bytes)) of \(FileFormat.size(d.totalBytes)) downloaded" : "\(FileFormat.size(d.bytes)) downloaded"
            return "\(bytes) · \(d.items.formatted()) of \(d.totalItems.formatted()) items" + (keep != .no ? " · kept" : "")
        }
        let export = d.export.map { " · as .\($0), read-only offline" } ?? ""
        switch keep {
        case .direct, .inherited: return "Kept downloaded · \(FileFormat.size(d.bytes))\(export)"
        case .no: return d.downloaded ? "Downloaded · may be removed to save space\(export)" : "In \(provider) only"
        }
    }
}
