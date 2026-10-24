import Foundation

private extension CloudMetadataCache {
    func enableProviderRetention(_ configuration: RetentionConfiguration, edits: URL, source: CloudContentSource, canonicalRoot: String? = nil) {
        let offline = CloudMetadataOwnership.offlineDirectory(for: source), account = source.accountID
        enableRetention(configuration) {
            let owners = CloudMetadataOwnership.restore(edits: edits, offline: offline, account: account, item: Item.self)
            guard let canonicalRoot else { return owners }
            return owners.mapValues { value in
                var value = value
                value.owner = CloudMetadataOwnership.root(value.owner, canonical: canonicalRoot)
                return value
            }
        }
    }
}

extension BoxClient {
    func enableMetadataRetention() {
        let edits = metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Edits")
        metadataCache.enableProviderRetention(
            .init(parents: { Set($0.parentID.map { [$0] } ?? []) }, roots: [BoxItem.rootID]), edits: edits, source: contentSource,
            canonicalRoot: BoxItem.rootID)
    }
}

extension DropboxClient {
    func enableMetadataRetention() {
        let edits = metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Edits")
        metadataCache.enableProviderRetention(
            .init(aliases: { Set($0.pathLower.map { [$0] } ?? []) }, parents: { [$0.parentPath] }, roots: [""]),
            edits: edits, source: contentSource)
    }
}

extension OneDriveClient {
    func enableMetadataRetention() {
        let edits = metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Edits")
        metadataCache.enableProviderRetention(
            .init(parents: { Set($0.parentID.map { [$0] } ?? []) }, roots: [""]), edits: edits, source: contentSource)
    }
}

extension DriveClient {
    func enableMetadataRetention() {
        metadataCache.storage.enableProviderRetention(
            .init(
                parents: { Set($0.parents ?? []) }, dependencies: { Set($0.shortcutDetails.map { [$0.targetId] } ?? []) },
                context: { key in
                    if key == "root" { return ["root"] }
                    if key.hasPrefix("folder:") { return [String(key.dropFirst("folder:".count))] }
                    return []
                }, roots: ["root"]),
            edits: metadataCache.directory.appendingPathComponent("Edits"), source: contentSource)
    }
}
