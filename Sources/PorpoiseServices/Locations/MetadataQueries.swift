import Foundation
import PorpoiseCore

/// "Recent Files": Spotlight's last-used dates (the Mac's equivalent of recentlyused:/files).
public final class RecentFilesQuery: NSObject {
    private let query = NSMetadataQuery()
    private let done: ([FileItem]) -> Void
    private static let maxAge: TimeInterval = 30 * 86400
    private static let maxResults = 200

    init(done: @escaping ([FileItem]) -> Void) {
        self.done = done
        super.init()
        let since = Date().addingTimeInterval(-Self.maxAge)
        query.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@ AND kMDItemContentTypeTree != 'public.folder'", since as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
    }

    @objc private func gathered() {
        query.stop()
        var items: [FileItem] = []
        for i in 0..<min(query.resultCount, Self.maxResults) {
            guard let r = query.result(at: i) as? NSMetadataItem, let p = r.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !p.contains("/Library/"), let it = FileItem.load(URL(fileURLWithPath: p)) else { continue }
            items.append(it)
        }
        done(items)
        NotificationCenter.default.removeObserver(self)
    }
}

/// Files carrying a tag (the sidebar's Tags section), found with Spotlight.
public final class MetadataListQuery: NSObject {
    private let query = NSMetadataQuery()
    private let done: ([FileItem]) -> Void

    init(predicate: NSPredicate, scopes: [Any] = [NSMetadataQueryLocalComputerScope], done: @escaping ([FileItem]) -> Void) {
        self.done = done
        super.init()
        query.predicate = predicate
        query.searchScopes = scopes
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
    }

    deinit {
        // Replaced before it finished gathering (the user moved on): stop searching.
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }

    static func tagged(_ tag: String, done: @escaping ([FileItem]) -> Void) -> MetadataListQuery {
        MetadataListQuery(predicate: NSPredicate(format: "kMDItemUserTags == %@", tag), done: done)
    }

    /// Finder Smart Folder (.savedSearch): its raw Spotlight query and scopes.
    static func smartFolder(_ file: URL, done: @escaping ([FileItem]) -> Void) -> MetadataListQuery? {
        guard let d = NSDictionary(contentsOf: file), let raw = d["RawQuery"] as? String,
              let pred = NSPredicate(fromMetadataQueryString: raw) else { return nil }
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

    @objc private func gathered() {
        query.stop()
        var items: [FileItem] = []
        for i in 0..<min(query.resultCount, 2000) {
            guard let r = query.result(at: i) as? NSMetadataItem, let p = r.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let it = FileItem.load(URL(fileURLWithPath: p)) else { continue }
            items.append(it)
        }
        NotificationCenter.default.removeObserver(self)
        done(items)
    }
}
