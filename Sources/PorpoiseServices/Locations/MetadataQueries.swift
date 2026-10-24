import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// "Recent Files": Spotlight's last-used dates (the Mac's equivalent of recentlyused:/files).
final class RecentFilesQuery {
    private let spotlight: SpotlightQuery
    private let files: MetadataFileLoad
    private static let maxAge: TimeInterval = 30 * 86400
    private static let maxResults = 200

    /// `done` gets the listing, including an explicit failure when Spotlight does not answer.
    init(done: @escaping (LocationListing) -> Void) {
        let files = MetadataFileLoad()
        self.files = files
        let since = Date().addingTimeInterval(-Self.maxAge)
        spotlight = SpotlightQuery(
            predicate: NSPredicate(format: "kMDItemLastUsedDate >= %@ AND kMDItemContentTypeTree != 'public.folder'", since as NSDate),
            scopes: [NSMetadataQueryUserHomeScope], sortedBy: [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)],
            limit: Self.maxResults
        ) { event in
            switch event {
            case .gathered(let paths):
                files.start(paths.filter { !$0.contains("/Library/") }.map { URL(fileURLWithPath: $0) }, done: done)
            case .unavailable:
                done(LocationListing(error: .provider("Spotlight did not answer. Try again or check Spotlight indexing in System Settings.")))
            case .progress, .updated: break
            }
        }
        spotlight.start()
    }

    deinit { spotlight.stop(); files.cancel() }
}

/// Files carrying a tag (the sidebar's Tags section), or matching a Finder Smart Folder, found with Spotlight.
final class MetadataListQuery {
    private let spotlight: SpotlightQuery
    private let files: MetadataFileLoad
    var query: NSMetadataQuery { spotlight.query }

    /// `done` gets the listing, including an explicit failure when Spotlight does not answer.
    init(predicate: NSPredicate, scopes: [Any] = [NSMetadataQueryLocalComputerScope], done: @escaping (LocationListing) -> Void) {
        let files = MetadataFileLoad()
        self.files = files
        spotlight = SpotlightQuery(predicate: predicate, scopes: scopes, limit: 2000) { event in
            switch event {
            case .gathered(let paths): files.start(paths.map { URL(fileURLWithPath: $0) }, done: done)
            case .unavailable:
                done(LocationListing(error: .provider("Spotlight did not answer. Try again or check Spotlight indexing in System Settings.")))
            case .progress, .updated: break
            }
        }
        spotlight.start()
    }

    // Replaced before it finished gathering (the user moved on): stop searching.
    deinit { spotlight.stop(); files.cancel() }

    static func tagged(_ tag: String, done: @escaping (LocationListing) -> Void) -> MetadataListQuery {
        MetadataListQuery(predicate: NSPredicate(format: "kMDItemUserTags == %@", tag), done: done)
    }

    /// Finder Smart Folder (.savedSearch): its raw Spotlight query and scopes.
    static func smartFolder(_ file: URL, done: @escaping (LocationListing) -> Void) -> MetadataListQuery? {
        guard let d = NSDictionary(contentsOf: file), let raw = d["RawQuery"] as? String,
            let pred = NSPredicate(fromMetadataQueryString: raw)
        else { return nil }
        let crit = d["SearchCriteria"] as? [String: Any]
        let scopes: [Any] = ((crit?["FXScopeArrayOfPaths"] as? [String]) ?? []).map { s -> Any in
            switch s {
            case "kMDQueryScopeHome": return NSMetadataQueryUserHomeScope
            case "kMDQueryScopeComputer": return NSMetadataQueryLocalComputerScope
            case "kMDQueryScopeAllIndexed": return NSMetadataQueryIndexedLocalComputerScope
            default: return URL(fileURLWithPath: s)
            }
        }
        return MetadataListQuery(predicate: pred, scopes: scopes.isEmpty ? [NSMetadataQueryLocalComputerScope] : scopes, done: done)
    }
}

/// File metadata can block on mounted volumes. One dedicated queue bounds the work; cancellation drops both
/// queued IO and delivery after navigation, without occupying a cooperative worker waiting for another task.
final class MetadataFileLoad {
    private static let queue = DispatchQueue(label: "app.porpoise.metadata-list", qos: .userInitiated)
    private let cancellation = DiskCancellation()
    func start(_ urls: [URL], load: @escaping (URL) -> FileItem? = { FileItem.load($0) }, done: @escaping (LocationListing) -> Void) {
        let cancellation = cancellation
        Self.queue.async {
            var items: [FileItem] = []
            for url in urls {
                guard !cancellation.isCancelled else { return }
                if let item = load(url) { items.append(item) }
            }
            DispatchQueue.main.async {
                guard !cancellation.isCancelled else { return }
                done(LocationListing(items: items))
            }
        }
    }
    func cancel() { cancellation.cancel() }
}
