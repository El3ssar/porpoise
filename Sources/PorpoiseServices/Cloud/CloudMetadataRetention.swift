import Foundation

/// Bookkeeping for a future cache owner. This does not enable eviction in `CloudMetadataCache`.
/// The caller supplies complete retained-payload byte counts (including keys/relationships and listing copies),
/// applies the returned removals, and runs the planner on its own serialized background queue.
struct CloudMetadataRetention {
    struct Limits: Sendable {
        var files: Int
        var listings: Int
        var bytes: Int
    }
    struct Owner: Equatable, Sendable {
        var items: Set<String> = []
        var subtrees: Set<String> = []
        var listings: Set<String> = []
    }
    struct Accounting: Equatable, Sendable {
        var files: Int
        var listings: Int
        var bytes: Int
        var protectedFiles: Int
        var protectedListings: Int
        var protectedBytes: Int
        var owners: Int
        var ownerReferences: Int
        var aliasConflicts: Int = 0
        var ordinaryFiles: Int { files - protectedFiles }
        var ordinaryListings: Int { listings - protectedListings }
        var ordinaryBytes: Int { bytes - protectedBytes }
    }
    struct Evictions: Equatable, Sendable {
        var files: Set<String> = []
        var listings: Set<String> = []
    }
    private struct File {
        var aliases: Set<String>
        var parents: Set<String>
        var dependencies: Set<String>
        var bytes: Int
        var used: UInt64
    }
    private struct Listing {
        var items: Set<String>
        var context: Set<String>
        var bytes: Int
        var used: UInt64
    }
    private var files: [String: File] = [:]
    private var listings: [String: Listing] = [:]
    private var owners: [String: Owner] = [:]
    private var clock: UInt64 = 0

    mutating func putFile(_ id: String, aliases: Set<String> = [], parents: Set<String> = [], dependencies: Set<String> = [], bytes: Int) {
        precondition(bytes >= 0)
        clock &+= 1
        files[id] = File(aliases: aliases, parents: parents, dependencies: dependencies, bytes: bytes, used: clock)
    }
    /// Canonical IDs referenced by a complete snapshot, plus its container or other required context.
    mutating func putListing(_ key: String, items: Set<String>, context: Set<String> = [], bytes: Int) {
        precondition(bytes >= 0)
        clock &+= 1
        listings[key] = Listing(items: items.union(context), context: context, bytes: bytes, used: clock)
    }
    mutating func forgetFile(_ id: String) { files[id] = nil }
    mutating func forgetListing(_ key: String) { listings[key] = nil }
    mutating func touchFile(_ id: String) {
        guard files[id] != nil else { return }
        clock &+= 1; files[id]?.used = clock
    }
    mutating func touchListing(_ key: String) {
        guard listings[key] != nil else { return }
        clock &+= 1; listings[key]?.used = clock
    }
    /// Replace an owner's complete set, or release it with nil. Unknown references remain registered so that
    /// metadata learned later receives the same protection. The integration must restore owners before pruning.
    mutating func setOwner(_ name: String, _ owner: Owner?) { owners[name] = owner }

    private func protection() -> (
        files: Set<String>, listings: Set<String>, parents: [String: Set<String>], canonical: [String: Set<String>], aliasConflicts: Int
    ) {
        // Canonical IDs take precedence. Conflicting provider aliases resolve conservatively to every candidate,
        // so an owner cannot lose a subtree because malformed metadata happened to arrive first.
        var canonical = Dictionary(uniqueKeysWithValues: files.keys.map { ($0, Set([$0])) })
        for (id, file) in files {
            for alias in file.aliases where files[alias] == nil {
                canonical[alias, default: []].insert(id)
            }
        }
        func resolve(_ id: String) -> Set<String> { canonical[id] ?? [id] }
        let parents = files.mapValues { Set($0.parents.flatMap(resolve)) }
        var ownedListings = Set(owners.values.flatMap(\.listings)).intersection(listings.keys)
        var protected = Set(owners.values.flatMap(\.items).flatMap(resolve))
        for key in ownedListings { protected.formUnion(listings[key]!.items.flatMap(resolve)) }
        let subtreeRoots = Set(owners.values.flatMap(\.subtrees).flatMap(resolve))
        var children: [String: Set<String>] = [:]
        for id in files.keys {
            for parent in parents[id] ?? [] { children[parent, default: []].insert(id) }
        }
        var visited: Set<String> = [], pending = Array(subtreeRoots)
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            protected.insert(id)
            pending += children[id] ?? []
        }
        // Offline folder ownership includes complete listings, so eviction cannot make an owned folder
        // unbrowsable on the next offline visit even though all its canonical members survived.
        for (key, listing) in listings where !Set(listing.context.flatMap(resolve)).isDisjoint(with: visited) {
            ownedListings.insert(key)
            protected.formUnion(listing.items.flatMap(resolve))
        }
        // Ancestors survive too, including chains through aliases and cyclic provider metadata.
        let context = files.mapValues { Set($0.parents.union($0.dependencies).flatMap(resolve)) }
        protected = Self.ancestors(of: protected, parents: context)
        return (protected.intersection(files.keys), ownedListings, context, canonical, canonical.values.filter { $0.count > 1 }.count)
    }

    private static func ancestors(of items: Set<String>, parents: [String: Set<String>]) -> Set<String> {
        var visited: Set<String> = [], pending = Array(items)
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            pending += parents[id] ?? []
        }
        return visited
    }

    var accounting: Accounting {
        let protected = protection()
        return Accounting(
            files: files.count, listings: listings.count,
            bytes: files.values.reduce(0) { $0 + $1.bytes } + listings.values.reduce(0) { $0 + $1.bytes },
            protectedFiles: protected.files.count, protectedListings: protected.listings.count,
            protectedBytes: protected.files.reduce(0) { $0 + files[$1]!.bytes }
                + protected.listings.reduce(0) { $0 + listings[$1]!.bytes },
            owners: owners.count,
            ownerReferences: owners.values.reduce(0) { $0 + $1.items.count + $1.subtrees.count + $1.listings.count },
            aliasConflicts: protected.aliasConflicts)
    }

    /// Bounds ordinary metadata; user-owned metadata is additive and separately accounted. A listing is removed
    /// whole. Members of every retained listing stay addressable by their canonical ID.
    mutating func prune(to limits: Limits) -> Evictions {
        precondition(limits.files >= 0 && limits.listings >= 0 && limits.bytes >= 0)
        let protected = protection()
        var result = Evictions()
        var ordinaryFiles = files.count - protected.files.count
        var ordinaryListings = listings.count - protected.listings.count
        var ordinaryBytes =
            files.filter { !protected.files.contains($0.key) }.values.reduce(0) { $0 + $1.bytes }
            + listings.filter { !protected.listings.contains($0.key) }.values.reduce(0) { $0 + $1.bytes }
        // A cached snapshot also needs its ancestors when it is revisited, before a new owner can attach.
        let contexts = listings.mapValues {
            Self.ancestors(of: Set($0.items.flatMap { protected.canonical[$0] ?? [$0] }), parents: protected.parents)
        }
        var members: [String: Int] = [:]
        for context in contexts.values { for id in context { members[id, default: 0] += 1 } }
        func overBudget() -> Bool { ordinaryFiles > limits.files || ordinaryListings > limits.listings || ordinaryBytes > limits.bytes }
        func older(_ a: String, _ b: String, _ stamp: (String) -> UInt64) -> Bool {
            stamp(a) == stamp(b) ? a < b : stamp(a) < stamp(b)
        }
        let oldListings = listings.keys.filter { !protected.listings.contains($0) }.sorted { older($0, $1) { listings[$0]!.used } }
        let oldFiles = files.keys.filter { !protected.files.contains($0) }.sorted { older($0, $1) { files[$0]!.used } }
        func removeListing(_ key: String) {
            guard let listing = listings.removeValue(forKey: key) else { return }
            result.listings.insert(key)
            ordinaryListings -= 1; ordinaryBytes -= listing.bytes
            for id in contexts[key]! { members[id, default: 0] -= 1 }
        }
        func removeFile(_ id: String) {
            guard let file = files.removeValue(forKey: id) else { return }
            result.files.insert(id)
            ordinaryFiles -= 1; ordinaryBytes -= file.bytes
        }
        // Satisfy the snapshot-count budget first, then prefer unused files over dropping useful snapshots.
        for key in oldListings where ordinaryListings > limits.listings { removeListing(key) }
        for id in oldFiles where overBudget() && (members[id] ?? 0) == 0 { removeFile(id) }
        for key in oldListings where overBudget() {
            guard listings[key] != nil else { continue }
            removeListing(key)
            let released = contexts[key]!.filter { files[$0] != nil && !protected.files.contains($0) && (members[$0] ?? 0) == 0 }
                .sorted { older($0, $1) { files[$0]!.used } }
            for id in released where overBudget() { removeFile(id) }
        }
        return result
    }
}
