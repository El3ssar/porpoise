import Foundation
import PorpoiseCore

/// The cloud commands for a selection, Download and Remove Download, for iCloud Drive and File Provider items as well
/// as the accounts Porpoise connects to: which ones the menus offer, and doing them. Two states only: an item is in the
/// cloud only, or also on this Mac (for accounts, kept current until Remove Download).
public enum CloudCommands {
    /// What the menus show for a selection.
    public struct Available: Equatable {
        /// Download: accounts keep the items on this Mac; iCloud Drive downloads them ("Download Now", as Finder).
        public var download = false
        public var downloadTitle = "Download"
        public var downloadEnabled = true
        public var removeDownload = false
        public var removeEnabled = true
        /// Why Download or Remove Download is disabled.
        public var reason: String?

        public init(
            download: Bool = false, downloadTitle: String = "Download", downloadEnabled: Bool = true, removeDownload: Bool = false,
            removeEnabled: Bool = true, reason: String? = nil
        ) {
            self.download = download
            self.downloadTitle = downloadTitle
            self.downloadEnabled = downloadEnabled
            self.removeDownload = removeDownload
            self.removeEnabled = removeEnabled
            self.reason = reason
        }

        public var isEmpty: Bool { !download && !removeDownload }
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
        let keeps = accountItems.map { service.keep(for: $0.url) }
        a.download = keeps.contains(.no)
        a.removeDownload = keeps.contains { $0 != .no }
        // On this Mac because a folder above is: only that folder can be removed.
        if case .inherited(let folder) = keeps.first, keeps.allSatisfy({ if case .inherited = $0 { return true } else { return false } }) {
            a.removeEnabled = false
            a.reason = "On this Mac because “\(folder)” is downloaded."
        }
        if a.download, let why = accountItems.lazy.compactMap({ service.keepDenial(for: $0.url) }).first {
            a.downloadEnabled = false
            a.reason = why
        }
        return a
    }

    /// iCloud Drive and File Provider items: Download Now and Remove Download, as Finder.
    private static func iCloud(_ items: [FileItem], cloud: (FileItem) -> (state: CloudState, isCloud: Bool)) -> Available {
        let clouds = items.map(cloud)
        guard clouds.contains(where: { $0.isCloud }) else { return Available() }
        var a = Available(downloadTitle: "Download Now")
        a.download = clouds.contains { $0.state == .cloudOnly } || items.contains(where: \.isBrowsableFolder)
        a.removeDownload = clouds.contains { $0.isCloud && $0.state != .cloudOnly }
        return a
    }

    // MARK: Doing them

    /// Download for iCloud Drive items (Download Now); returns the account items, which the app keeps on this Mac
    /// after counting what it takes (KeepDownloadedSheet).
    public static func downloadNow(_ urls: [URL]) -> [URL] {
        let local = urls.filter(\.isFileURL)
        if !local.isEmpty { CloudActions.download(local) }
        return urls.filter(isAccountItem).filter { service()?.keep(for: $0) == CloudKeep.no }
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
        let items = plan.items == 1 ? "1 item" : "\(FileFormat.count(plan.items)) items"
        let what = "\(FileFormat.size(plan.bytes)) in \(items)."
        guard plan.fits else { return "Needs \(FileFormat.size(plan.bytes)); you have \(FileFormat.size(max(0, plan.available))) available." }
        let more = folder ? " New items added to this folder will download too." : ""
        return "\(what) You have \(FileFormat.size(plan.available)) available on this Mac.\(more)"
    }

    /// Settings' choices for recently opened files (nil: no limit).
    public static var cacheLimits: [(title: String, bytes: Int64?)] {
        [
            (FileFormat.byteLimitTitle(1 << 30), 1 << 30), (FileFormat.byteLimitTitle(5 << 30), 5 << 30),
            (FileFormat.byteLimitTitle(10 << 30), 10 << 30), (FileFormat.byteLimitTitle(25 << 30), 25 << 30), (FileFormat.byteLimitTitle(nil), nil),
        ]
    }

    /// "Google Drive · me@x: 3.1 GB downloaded · 820 MB of recently opened files".
    public static func usageText(_ u: CloudOfflineUsage, account: String) -> String {
        "\(account): \(FileFormat.size(u.kept)) downloaded" + (u.recent > 0 ? " · \(FileFormat.size(u.recent)) of recently opened files" : "")
    }

    /// The line the sign-out confirmation adds when the account has copies on this Mac.
    public static func signOutLine(bytes: Int64, provider: String) -> String? {
        guard bytes > 0 else { return nil }
        return "The \(FileFormat.size(bytes)) of offline copies on this Mac will be deleted. Your files stay in \(provider)."
    }

    /// Properties' "On this Mac" row: in the cloud only, or on this Mac (downloading, how much, and why).
    public static func summaryText(_ d: CloudOfflineDetails, folder: Bool, provider: String) -> String {
        if let why = d.error { return why }
        if let p = d.progress { return "Downloading \(Int(p * 100)) %" }
        let keep = CloudKeep(d)
        guard keep != .no else { return "In \(provider) only" }
        var with = ""
        if case .inherited(let parent) = keep { with = " · with “\(parent)”" }
        if folder {
            guard d.totalItems > 0 else { return "Downloaded" + with }
            if d.items < d.totalItems { return "Downloading · \(FileFormat.count(d.items)) of \(FileFormat.count(d.totalItems)) items" + with }
            return "Downloaded · \(FileFormat.size(d.bytes)) in \(FileFormat.count(d.totalItems)) items" + with
        }
        guard d.downloaded || d.bytes > 0 else { return "Waiting to download" + with }
        let export = d.export.map { " · as .\($0), read-only offline" } ?? ""
        return "Downloaded" + (d.bytes > 0 ? " · \(FileFormat.size(d.bytes))" : "") + export + with
    }
}
