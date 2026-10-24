import Foundation

/// Internal offline ownership capability; unrelated public content sources do not need cache APIs.
protocol CloudMetadataOwningContentSource: AnyObject {
    func setMetadataOwner(_ name: String, owner: CloudMetadataRetention.Owner?, complete: Bool)
}

enum CloudMetadataOwnership {
    static func key(_ family: String, directory: URL) -> String {
        family + ":" + cloudObjectKey(directory.standardizedFileURL.path)
    }
    static func union(_ a: CloudMetadataRetention.Owner, _ b: CloudMetadataRetention.Owner) -> CloudMetadataRetention.Owner {
        .init(items: a.items.union(b.items), subtrees: a.subtrees.union(b.subtrees), listings: a.listings.union(b.listings))
    }
    static func offline(_ index: CloudOfflineIndex) -> CloudMetadataRetention.Owner {
        var ids = Set(index.entries.keys).union(index.pins), pending = Array(ids)
        while let id = pending.popLast() {
            let item = index.items[id] ?? index.entries[id]?.item
            for parent in item?.parents ?? [] where ids.insert(parent).inserted { pending.append(parent) }
        }
        return .init(items: ids, subtrees: index.pins)
    }
    static func valid(_ index: CloudOfflineIndex, account: String) -> Bool {
        index.version == 1
            && index.items.allSatisfy { $0.key == $0.value.ref.item && $0.value.ref.account == account }
            && index.entries.allSatisfy { $0.key == $0.value.item.ref.item && $0.value.item.ref.account == account }
    }
    static func offlineDirectory(for source: CloudContentSource) -> URL {
        source.offlineDirectory
            ?? Settings.supportFolder.appendingPathComponent("Cloud").appendingPathComponent(cloudObjectKey(source.providerTitle))
            .appendingPathComponent(cloudObjectKey(source.accountID))
    }
    static func missing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
    }

    /// Called on the private retention queue, before any eviction. Never opens/hashes the editable bytes.
    static func restore<Item: CloudMetadataItem>(
        edits: URL, offline: URL, account: String, item: Item.Type
    ) -> [String: CloudMetadataCache<Item>.RestoredOwner] {
        var files: [Item] = [], editsComplete = true
        do {
            for url in try FileManager.default.contentsOfDirectory(at: edits, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                do {
                    let session = try JSONDecoder().decode(CloudEditSession<Item>.self, from: Data(contentsOf: url))
                    guard session.localURL.standardizedFileURL.path.hasPrefix(edits.standardizedFileURL.path + "/") else {
                        editsComplete = false; continue
                    }
                    files.append(session.file)
                } catch { editsComplete = false }
            }
        } catch { editsComplete = missing(error) }
        var result = [
            key("edits", directory: edits): CloudMetadataCache<Item>.RestoredOwner(
                owner: .init(items: Set(files.map(\.id))), files: files, complete: editsComplete)
        ]
        let name = key("offline", directory: offline)
        do {
            var index = try JSONDecoder().decode(CloudOfflineIndex.self, from: Data(contentsOf: offline.appendingPathComponent("index.json")))
            guard valid(index, account: account) else {
                result[name] = .init(owner: .init(), complete: false); return result
            }
            // Match the offline store's recovery boundary: only existing, complete objects own recent metadata.
            index.entries = index.entries.filter { _, entry in
                let url = offline.appendingPathComponent(entry.path).standardizedFileURL
                guard url.path.hasPrefix(offline.standardizedFileURL.path + "/objects/"),
                    let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                else { return false }
                return Int64(size) == entry.size
            }
            result[name] = .init(owner: self.offline(index))
        } catch { result[name] = .init(owner: .init(), complete: missing(error)) }
        return result
    }
}
