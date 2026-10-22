import Foundation

/// Which of the standard Finder tags some file in the home folder carries, kept current by Spotlight: the sidebar lists
/// only those, as Finder's does. One live query per tag, asking for a single match.
final class UsedTagsQuery {
    private var queries: [SpotlightQuery] = []
    private var used: Set<String> = []
    private var answered: Set<String> = []
    private var unavailable = false

    /// `changed` gets the tags in use once every tag has answered, and again whenever that changes; nil when Spotlight
    /// can't say (then every tag is listed).
    init(tags: [String], changed: @escaping (Set<String>?) -> Void) {
        for tag in tags {
            let q = SpotlightQuery(
                predicate: NSPredicate(format: "kMDItemUserTags == %@", tag), scopes: [NSMetadataQueryUserHomeScope], limit: 1, live: true
            ) { [weak self] event in
                guard let self else { return }
                switch event {
                case .gathered(let paths), .updated(let paths, _):
                    if paths.isEmpty { self.used.remove(tag) } else { self.used.insert(tag) }
                    self.answered.insert(tag)
                case .unavailable:
                    self.unavailable = true
                case .progress:
                    return
                }
                if self.unavailable {
                    changed(nil)
                } else if self.answered.count == tags.count {
                    changed(self.used)
                }
            }
            queries.append(q)
            q.start()
        }
    }

    deinit { queries.forEach { $0.stop() } }
}
