import Foundation
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
        try Data("broken".utf8).write(to: scratch.url.appendingPathComponent("metadata.json"))
        #expect(CloudMetadataCache<Item>(directory: scratch.url).file(item.id) == nil)
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
