import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudProviderMechanicsTests {
    private struct Record: CloudRangeDownloadRecord {
        var version = 1
        var operationID = UUID()
        var offset: Int64 = 0
        var downloadRanges: [CloudDownloadRange]?
        var fingerprint: JobJournal.Fingerprint?
    }
    private struct Item: CloudMetadataItem, Equatable { var id: String; var parent: String }

    @Test func emptyDownloadPersistsWithoutARequestAndInvalidSizesFailClosed() async throws {
        let scratch = try Scratch(), partial = try scratch.file("partial", "discard")
        let journal = CloudJournal<Record>(folder: scratch.url.appendingPathComponent("journal"))
        let record = Record()
        let empty = try await CloudRangeDownload.run(
            total: 0, partial: partial, record: record, context: .init(), maximumConnections: 8,
            save: { try journal.save($0) },
            fetch: { _, _ in
                Issue.record("An empty range must not be requested"); throw URLError(.badServerResponse)
            })
        #expect(empty.offset == 0 && empty.downloadRanges == [] && empty.fingerprint?.size == 0)
        #expect(try journal.load(record.operationID)?.fingerprint == empty.fingerprint)
        await #expect(throws: CloudTransferError.self) {
            try await CloudRangeDownload.run(
                total: -1, partial: partial, record: record, context: .init(), maximumConnections: 8,
                save: { try journal.save($0) }, fetch: { _, _ in throw URLError(.badServerResponse) })
        }
        try journal.claim(record.operationID)
        #expect(throws: CloudJournalError.self) { try journal.claim(record.operationID) }
        journal.release(record.operationID)
        try journal.claim(record.operationID); journal.release(record.operationID)
    }

    @Test func metadataPersistsOpaqueCursorAndPatchesMembership() throws {
        let scratch = try Scratch()
        let cache = CloudMetadataCache<Item>(directory: scratch.url)
        let item = Item(id: "opaque:item/ID", parent: "root")
        cache.store([item], key: "root")
        cache.setCursor("opaque/0==?", scope: "root")
        let reopened = CloudMetadataCache<Item>(directory: scratch.url)
        #expect(reopened.snapshot("root")?.files == [item] && reopened.cursor("root") == "opaque/0==?")
        let moved = Item(id: item.id, parent: "other")
        reopened.apply([moved], removed: [], belongs: { $0 == $1.parent })
        #expect(reopened.snapshot("root")?.files == [] && reopened.file(item.id) == moved)
        reopened.flush()  // Its pending write would replace the broken file.
        try Data("broken".utf8).write(to: scratch.url.appendingPathComponent("metadata.json"))
        #expect(CloudMetadataCache<Item>(directory: scratch.url).file(item.id) == nil)
    }

    /// Updates write the file later, once, off the lock; a cache opened on the folder sees them anyway, a cleared
    /// cache stays cleared, and a folder removed meanwhile is not made again.
    @Test func metadataWritesAreDeferredAndCoalesced() throws {
        let scratch = try Scratch(), file = scratch.url.appendingPathComponent("metadata.json")
        let cache = CloudMetadataCache<Item>(directory: scratch.url)
        for index in 0..<50 { cache.learn([Item(id: "\(index)", parent: "root")], since: cache.generation) }
        cache.setCursor("c1", scope: "root")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(CloudMetadataCache<Item>(directory: scratch.url).file("49") == Item(id: "49", parent: "root"))
        let written = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        // Nothing changes: the same cursor again, a listing that isn't there.
        cache.setCursor("c1", scope: "root"); cache.invalidate("missing"); cache.flush()
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == written)
        cache.remember([Item(id: "late", parent: "root")]); cache.clear()
        cache.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let gone = scratch.url.appendingPathComponent("gone")
        let orphan = CloudMetadataCache<Item>(directory: gone)
        orphan.remember([Item(id: "a", parent: "root")])
        try FileManager.default.removeItem(at: gone)
        orphan.flush()
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    /// A page of many changes patches every listing the way one change at a time would.
    @Test func applyingManyChangesPatchesListingsLikeOneAtATime() throws {
        let scratch = try Scratch()
        let bulk = CloudMetadataCache<Item>(directory: scratch.url.appendingPathComponent("bulk"))
        let single = CloudMetadataCache<Item>(directory: scratch.url.appendingPathComponent("single"))
        let listed = (0..<30).map { Item(id: "\($0)", parent: $0 % 2 == 0 ? "a" : "b") }
        for cache in [bulk, single] {
            cache.store(listed.filter { $0.parent == "a" }, key: "a"); cache.store(listed.filter { $0.parent == "b" }, key: "b")
        }
        let changes = (0..<20).map { Item(id: "\($0 * 2)", parent: $0 % 3 == 0 ? "b" : "a") } + [Item(id: "new", parent: "a")]
        bulk.apply(changes, removed: ["5", "7"], belongs: { $0 == $1.parent })
        single.apply([], removed: ["5", "7"], belongs: { $0 == $1.parent })
        for change in changes { single.apply([change], removed: [], belongs: { $0 == $1.parent }) }
        #expect(bulk.snapshot("a")?.files == single.snapshot("a")?.files)
        #expect(bulk.snapshot("b")?.files == single.snapshot("b")?.files)
        #expect(bulk.snapshot("a")?.files.last?.id == "new" && bulk.snapshot("b")?.files.contains { $0.id == "5" } == false)
    }

    /// A listing fetched before a change made here lands after it: it doesn't put the old metadata back (a rename read
    /// the old name right after it was made, under load).
    @Test func aListingFetchedBeforeAChangeDoesNotUndoIt() throws {
        let scratch = try Scratch()
        let cache = CloudMetadataCache<Item>(directory: scratch.url)
        let since = cache.generation
        cache.remember([Item(id: "a", parent: "moved")])
        cache.store([Item(id: "a", parent: "root"), Item(id: "b", parent: "root")], key: "root", since: since)
        #expect(cache.file("a")?.parent == "moved" && cache.file("b")?.parent == "root")
        #expect(cache.snapshot("root")?.files.first { $0.id == "a" }?.parent == "moved")
        cache.apply([Item(id: "a", parent: "root")], removed: [], belongs: { _, _ in true }, since: since)
        #expect(cache.file("a")?.parent == "moved")
        // Fetched after the change: it's the newer one.
        cache.store([Item(id: "a", parent: "later")], key: "root", since: cache.generation)
        #expect(cache.file("a")?.parent == "later")
    }

    @Test func credentialFactoriesIsolateProvidersEvenWithMatchingAccountAndAppIDs() throws {
        let account = UUID(), dropbox = CredentialStores.cloud(providerID: "dropbox"), box = CredentialStores.cloud(providerID: "box")
        try dropbox.save("first", clientID: "same-app", accountID: account)
        #expect(try box.read(clientID: "same-app", accountID: account) == nil)
        try box.save("second", clientID: "same-app", accountID: account)
        #expect(try dropbox.read(clientID: "same-app", accountID: account) == "first")
        try dropbox.remove(clientID: "same-app", accountID: account)
        #expect(try box.read(clientID: "same-app", accountID: account) == "second")
        try box.remove(clientID: "same-app", accountID: account)
    }

    @Test func sharedPKCERejectsDuplicateStateAndFragments() throws {
        let redirect = URL(string: "http://127.0.0.1:12345/oauth/callback")!
        let transaction = try CloudPKCE(clientID: "app", redirectURL: redirect)
        let valid = URL(string: redirect.absoluteString + "?state=\(transaction.state)&code=one")!
        #expect(try transaction.code(from: valid) == "one")
        #expect(throws: CloudOAuthError.self) { try transaction.code(from: URL(string: valid.absoluteString + "&state=duplicate")!) }
        #expect(throws: CloudOAuthError.self) { try transaction.code(from: URL(string: valid.absoluteString + "#fragment")!) }
    }
}
