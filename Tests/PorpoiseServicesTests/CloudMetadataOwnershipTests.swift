import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudMetadataOwnershipTests {
    private struct File: CloudMetadataItem { let id: String; var parent: String? = nil }

    @Test func restorationProtectsRealOfflineBytesPinsAndEditRecordsWithoutOpeningEditableBytes() throws {
        let scratch = try Scratch(), edits = try scratch.folder("Edits"), offline = try scratch.folder("Offline")
        let object = try scratch.file("Offline/objects/cached", "abc")
        let folder = CloudRemoteItem(ref: .init(account: "fixture", item: "folder"), name: "Folder", parents: ["root"], isFolder: true)
        let file = CloudRemoteItem(ref: .init(account: "fixture", item: "cached"), name: "Cached", parents: ["folder"])
        let historical = CloudRemoteItem(ref: .init(account: "fixture", item: "historical"), name: "Old")
        var index = CloudOfflineIndex()
        index.items = ["folder": folder, "cached": file, "historical": historical]
        index.entries["cached"] = .init(item: file, path: "objects/cached", size: 3, lastUsed: Date())
        index.entries["missing"] = .init(
            item: .init(ref: .init(account: "fixture", item: "missing"), name: "Missing"), path: "objects/missing", size: 1, lastUsed: Date())
        index.pins = ["folder"]
        try JSONEncoder().encode(index).write(to: offline.appendingPathComponent("index.json"))
        let session = CloudEditSession(id: UUID(), localURL: edits.appendingPathComponent("not-present"), file: File(id: "edit"), sentHash: "hash")
        try JSONEncoder().encode(session).write(to: edits.appendingPathComponent("session.json"))
        let restored = CloudMetadataOwnership.restore(edits: edits, offline: offline, account: "fixture", item: File.self)
        let offlineOwner = try #require(restored[CloudMetadataOwnership.key("offline", directory: offline)])
        let editOwner = try #require(restored[CloudMetadataOwnership.key("edits", directory: edits)])
        #expect(offlineOwner.complete && offlineOwner.owner.items == ["cached", "folder", "root"] && offlineOwner.owner.subtrees == ["folder"])
        #expect(editOwner.complete && editOwner.files.map(\.id) == ["edit"])
        #expect(!FileManager.default.fileExists(atPath: session.localURL.path))
        #expect(try Data(contentsOf: object) == Data("abc".utf8))
    }

    @Test func missingOwnershipIsEmptyButCorruptOrMismatchedOwnershipIsUnknown() throws {
        let scratch = try Scratch(), edits = try scratch.folder("Edits"), offline = try scratch.folder("Offline")
        func restore() -> [String: CloudMetadataCache<File>.RestoredOwner] {
            CloudMetadataOwnership.restore(edits: edits, offline: offline, account: "fixture", item: File.self)
        }
        #expect(restore().values.allSatisfy { $0.complete && $0.owner.items.isEmpty })
        try Data("broken".utf8).write(to: edits.appendingPathComponent("session.json"))
        var index = CloudOfflineIndex()
        index.items["other"] = .init(ref: .init(account: "different-account", item: "other"), name: "Other")
        try JSONEncoder().encode(index).write(to: offline.appendingPathComponent("index.json"))
        #expect(restore().values.allSatisfy { !$0.complete })
        let outside = CloudEditSession(
            id: UUID(), localURL: scratch.url.appendingPathComponent("outside"), file: File(id: "escape"), sentHash: "hash")
        try JSONEncoder().encode(outside).write(to: edits.appendingPathComponent("session.json"))
        let owner = try #require(restore()[CloudMetadataOwnership.key("edits", directory: edits)])
        #expect(!owner.complete && owner.files.isEmpty)
    }

    private final class Source: CloudContentSource, CloudMetadataOwningContentSource, @unchecked Sendable {
        struct Event { let held: CloudMetadataRetention.Owner?; let pinsOnDisk: Set<String> }
        let fake = FakeContentSource(), directory: URL
        let events = Locked<[Event]>([])
        init(_ directory: URL) { self.directory = directory }
        var accountID: String { fake.accountID }
        var providerTitle: String { fake.providerTitle }
        var offlineDirectory: URL? { directory }
        var isOffline: Bool { fake.isOffline }
        var onChanges: (@Sendable (CloudChangeBatch) -> Void)? {
            get { fake.onChanges }
            set { fake.onChanges = newValue }
        }
        func ref(for url: URL) -> CloudItemRef? { fake.ref(for: url) }
        func url(for item: CloudRemoteItem) -> URL { fake.url(for: item) }
        func cachedItem(_ ref: CloudItemRef) -> CloudRemoteItem? { fake.cachedItem(ref) }
        func item(_ ref: CloudItemRef) async throws -> CloudRemoteItem { try await fake.item(ref) }
        func children(_ folder: CloudItemRef) async throws -> [CloudRemoteItem] { try await fake.children(folder) }
        func download(_ item: CloudRemoteItem, to partial: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
            try await fake.download(item, to: partial, progress: progress)
        }
        func setMetadataOwner(_ name: String, owner: CloudMetadataRetention.Owner?, complete: Bool) {
            let disk = (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
                .flatMap { try? JSONDecoder().decode(CloudOfflineIndex.self, from: $0) }
            events.append(.init(held: owner, pinsOnDisk: disk?.pins ?? []))
        }
    }

    @Test func pinProtectionPrecedesTheWriteAndReleaseFollowsTheDurableCommit() async throws {
        let scratch = try Scratch(), source = Source(scratch.url.appendingPathComponent("Offline"))
        let folder = source.fake.add("folder", folder: true)
        let store = try CloudOfflineStore(source: source, directory: source.directory)
        try await store.remember([folder])
        try await store.pin([folder.ref])
        #expect(source.events.value.contains { $0.held?.subtrees.contains("folder") == true && !$0.pinsOnDisk.contains("folder") })
        #expect(source.events.value.last?.held?.subtrees == ["folder"] && source.events.value.last?.pinsOnDisk == ["folder"])
        try await store.unpin([folder.ref])
        #expect(source.events.value.last?.held?.subtrees.isEmpty == true && source.events.value.last?.pinsOnDisk.isEmpty == true)
        try await store.pin([folder.ref])
        let index = source.directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await store.unpin([folder.ref]) }
        #expect(source.events.value.last?.held?.subtrees == ["folder"])
        try FileManager.default.removeItem(at: index)
        try await store.unpin([folder.ref])
        #expect(source.events.value.last?.held?.subtrees.isEmpty == true)
        try await store.wipe()
        #expect(source.events.value.last?.held == nil)
    }

    private struct Engine: CloudEditEngine {
        let directory: URL
        var unavailable: Error { CloudContentError.notFound }
        var sourceChanged: Error { CloudContentError.changed }
        func checkConnection() throws {}
        func canUseCached(after error: Error) -> Bool { false }
        func identity(_ file: File) -> String { file.id }
        func revision(_ file: File) -> String? { "revision" }
        func hash(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
        func uploadSource(_ operation: UUID) -> URL? { nil }
        func prepare(_ file: File, id: UUID, directory: URL, context: CloudTransferContext) async throws -> (File, URL) {
            let url = directory.appendingPathComponent(id.uuidString)
            try Data("initial".utf8).write(to: url)
            return (file, url)
        }
        func validate(_ file: File) async throws {}
        func publish(_ local: URL, file: File, operation: UUID, copyPath: String?, context: CloudTransferContext) async throws -> File {
            copyPath == nil ? file : File(id: "copy", parent: file.parent)
        }
        func prepareReplacement(_ file: File) async throws -> File { file }
        func conflict(_ error: Error) -> Bool { false }
        func remoteCopy(_ file: File, beside: URL) async -> URL? { nil }
    }

    @Test func editIdentityIsProtectedBeforeWritingAndOldIdentityIsReleasedAfterCommit() async throws {
        let scratch = try Scratch(), events = Locked<[(held: Set<String>, disk: Set<String>)]>([])
        let store = CloudEditSessionStore(engine: Engine(directory: scratch.url)) { files, complete in
            let disk = ((try? FileManager.default.contentsOfDirectory(at: scratch.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.compactMap { url in
                    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CloudEditSession<File>.self, from: $0) }?.file.id
                }
            events.append((Set(files.map(\.id)), Set(disk)))
        }
        let session = try await store.openSession(File(id: "original"))
        #expect(events.value.contains { $0.held == ["original"] && $0.disk.isEmpty })
        _ = try await store.saveSession(session.id, copyPath: "copy")
        #expect(events.value.contains { $0.held == ["original", "copy"] && $0.disk == ["original"] })
        #expect(events.value.last?.held == ["copy"] && events.value.last?.disk == ["copy"])
    }
}
