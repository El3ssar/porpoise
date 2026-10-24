import Foundation
import PorpoiseCore

/// A visible source owns complete listings and their context for as long as it can paint them.
protocol CloudMetadataRetainingProvider: AnyObject {
    func retainMetadata(for folders: Set<URL>) -> [CloudMetadataLease]
}

private struct MetadataOwners<Item: CloudMetadataItem> {
    private var groups: [ObjectIdentifier: (CloudMetadataCache<Item>, CloudMetadataRetention.Owner, [Item])] = [:]
    mutating func add(_ cache: CloudMetadataCache<Item>, items: Set<String>, listings: Set<String> = [], files: [Item] = []) {
        let id = ObjectIdentifier(cache)
        var group = groups[id] ?? (cache, .init(), [])
        group.1.items.formUnion(items); group.1.listings.formUnion(listings); group.2 += files
        groups[id] = group
    }
    func leases() -> [CloudMetadataLease] { groups.values.map { $0.0.retainMetadata($0.1, files: $0.2) } }
}

extension BoxProvider: CloudMetadataRetainingProvider {
    func retainMetadata(for folders: Set<URL>) -> [CloudMetadataLease] {
        let keys = Set(folders.compactMap { try? location($0).apiID })
        return [client.metadataCache.retainMetadata(.init(items: keys, listings: keys))]
    }
}

extension DriveProvider: CloudMetadataRetainingProvider {
    func retainMetadata(for folders: Set<URL>) -> [CloudMetadataLease] {
        guard let client else { return [] }
        let locations = folders.compactMap { try? location($0) }
        let keys = Set(locations.map { client.metadataCache.key($0) })
        let items = Set(
            locations.compactMap { location -> String? in
                switch location.collection {
                case .myDrive: return "root"
                case .folder(let id, _): return id
                default: return nil
                }
            })
        return [client.metadataCache.storage.retainMetadata(.init(items: items, listings: keys))]
    }
}

extension DropboxProvider: CloudMetadataRetainingProvider {
    func retainMetadata(for folders: Set<URL>) -> [CloudMetadataLease] {
        var owners = MetadataOwners<DropboxItem>()
        for folder in folders {
            guard let location = try? location(folder), let scoped = try? scoped(folder) else { continue }
            let key = location.itemID == "collection:team" ? "" : location.itemID
            let cache = location.itemID == "collection:team" ? client.metadataCache : scoped.metadataCache
            owners.add(cache, items: [key], listings: [key])
        }
        return owners.leases()
    }
}

extension OneDriveProvider: CloudMetadataRetainingProvider {
    func retainMetadata(for folders: Set<URL>) -> [CloudMetadataLease] {
        var owners = MetadataOwners<OneDriveItem>()
        for folder in folders {
            guard let location = try? location(folder), let scoped = try? scoped(folder) else { continue }
            owners.add(scoped.metadataCache, items: [location.itemID], listings: [location.itemID])
            // Shared collection rows name another drive's canonical records. The complete collection retains
            // typed metadata even if that drive pruned before this main-thread ownership refresh arrived.
            if location.itemID == "collection:shared", let snapshot = scoped.metadataCache.snapshot(location.itemID) {
                for (driveID, files) in Dictionary(grouping: snapshot.files, by: \.driveID) {
                    owners.add(drive(driveID).metadataCache, items: Set(files.map(\.id)), files: files)
                }
            }
        }
        return owners.leases()
    }
}
