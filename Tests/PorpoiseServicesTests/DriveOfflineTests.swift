import CryptoKit
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct DriveOfflineTests {
    func stats(_ server: FakeDriveServer) async throws -> (requests: [String], concurrent: Int) {
        let json = try await server.stats()
        return (json["requests"] as? [String] ?? [], json["maxConcurrentMedia"] as? Int ?? 0)
    }
    private func files(_ root: URL) throws -> Int {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        return try e.allObjects.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }.count
    }
    @Test func keepTwoHundredThenRevisionTrashAndLostCursorReconcile() async throws {
        let scratch = try Scratch()
        let data = Data("fixture bytes".utf8)
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var files: [[String: Any]] = [["id": "kept-folder", "name": "Kept", "mimeType": "application/vnd.google-apps.folder", "parents": ["root"]]]
        var media: [String: String] = [:]
        for n in 0..<200 {
            let id = "kept-\(n)"
            files.append([
                "id": id, "name": "File \(n).txt", "mimeType": "text/plain", "parents": ["kept-folder"],
                "size": String(data.count), "version": "1", "headRevisionId": "revision-1", "md5Checksum": md5,
            ])
            media[id] = data.base64EncodedString()
        }
        let fixture = scratch.url.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: ["files": files, "media": media, "rootIDs": ["kept-folder"], "drives": []]).write(to: fixture)
        let server = try FakeDriveServer(fixture: fixture, latencyMS: 50)
        let client = try DriveMutationTests().client(server, folder: scratch.url.appendingPathComponent("Journal"))
        let source = client.contentSource
        let store = try CloudOfflineStore(source: source, directory: scratch.url.appendingPathComponent("Offline"))
        let keeper = CloudPinKeeper(store: store)
        let ref = CloudItemRef(account: source.accountID, item: "kept-folder")
        try await store.pin([ref])
        await keeper.start()
        try await client.pollChanges()
        let initial = await store.snapshot()
        #expect(initial.entries.count == 200)
        for entry in initial.entries.values { #expect(try entry.item.checksum?.verify(store.directory.appendingPathComponent(entry.path)) == true) }
        let firstStats = try await stats(server)
        #expect(firstStats.concurrent <= 2)
        #expect(firstStats.requests.filter { $0.contains("alt=media") }.count == 200)
        #expect(try self.files(store.directory.appendingPathComponent("objects")) == 200)
        let changed = Data("new revision".utf8)
        let changedMD5 = Insecure.MD5.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        media["kept-0"] = changed.base64EncodedString()
        try await server.control(
            [
                "media": media,
                "remoteChanges": [
                    [
                        "file": [
                            "id": "kept-0", "version": "2",
                            "headRevisionId": "revision-2", "size": String(changed.count), "md5Checksum": changedMD5,
                        ]
                    ]
                ],
            ])
        try await client.pollChanges()
        await expectEventually(timeout: 30) { await store.snapshot().entries["kept-0"]?.item.revision == "revision-2" }
        try await server.control(["remoteChanges": [["file": ["id": "kept-1", "trashed": true]]]])
        try await client.pollChanges()
        await expectEventually(timeout: 30) { await store.snapshot().entries.count == 199 }
        try await server.control(["remoteChanges": [["fileId": "kept-2", "removed": true]], "changeFaults": [410]])
        try await client.pollChanges()
        await expectEventually(timeout: 30) { await store.snapshot().entries.count == 198 }
        let count = try self.files(store.directory.appendingPathComponent("objects"))
        #expect(count == 198)
        print(
            "DRIVE_OFFLINE HTTP 50ms: 200 MD5 verified; maxConcurrent=\(firstStats.concurrent); files 200 -> \(count) after revision/trash/410; zero leftovers"
        )
        await keeper.stop(); try await store.wipe()
    }
}
