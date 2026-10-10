import Foundation
import PorpoiseCore

/// "Recent Files": Spotlight's last-used dates (the Mac's equivalent of recentlyused:/files).
final class RecentFilesQuery {
    private let spotlight: SpotlightQuery
    private static let maxAge: TimeInterval = 30 * 86400
    private static let maxResults = 200

    /// `done` gets the files (none when Spotlight doesn't answer).
    init(done: @escaping ([FileItem]) -> Void) {
        let since = Date().addingTimeInterval(-Self.maxAge)
        spotlight = SpotlightQuery(
            predicate: NSPredicate(format: "kMDItemLastUsedDate >= %@ AND kMDItemContentTypeTree != 'public.folder'", since as NSDate),
            scopes: [NSMetadataQueryUserHomeScope], sortedBy: [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)],
            limit: Self.maxResults
        ) { event in
            switch event {
            case .gathered(let paths): done(paths.filter { !$0.contains("/Library/") }.compactMap { FileItem.load(URL(fileURLWithPath: $0)) })
            case .unavailable: done([])
            case .progress, .updated: break
            }
        }
        spotlight.start()
    }

    deinit { spotlight.stop() }
}

/// Files carrying a tag (the sidebar's Tags section), or matching a Finder Smart Folder, found with Spotlight.
final class MetadataListQuery {
    private let spotlight: SpotlightQuery
    var query: NSMetadataQuery { spotlight.query }

    /// `done` gets the files (none when Spotlight doesn't answer).
    init(predicate: NSPredicate, scopes: [Any] = [NSMetadataQueryLocalComputerScope], done: @escaping ([FileItem]) -> Void) {
        spotlight = SpotlightQuery(predicate: predicate, scopes: scopes, limit: 2000) { event in
            switch event {
            case .gathered(let paths): done(paths.compactMap { FileItem.load(URL(fileURLWithPath: $0)) })
            case .unavailable: done([])
            case .progress, .updated: break
            }
        }
        spotlight.start()
    }

    // Replaced before it finished gathering (the user moved on): stop searching.
    deinit { spotlight.stop() }

    static func tagged(_ tag: String, done: @escaping ([FileItem]) -> Void) -> MetadataListQuery {
        MetadataListQuery(predicate: NSPredicate(format: "kMDItemUserTags == %@", tag), done: done)
    }

    /// Finder Smart Folder (.savedSearch): its raw Spotlight query and scopes.
    static func smartFolder(_ file: URL, done: @escaping ([FileItem]) -> Void) -> MetadataListQuery? {
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
