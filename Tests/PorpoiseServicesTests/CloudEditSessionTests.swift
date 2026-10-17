import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudEditSessionTests {
    @Test func readsLegacyDriveRecordsAndWritesSharedSchema() throws {
        let session = DriveEditSession(
            id: UUID(), localURL: URL(fileURLWithPath: "/tmp/edit"),
            file: DriveFile(id: "opaque-id", name: "notes", mimeType: "text/plain"), sentHash: "old-md5")
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        record["sentMD5"] = record.removeValue(forKey: "sentHash")
        record["state"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudEditState.conflict))
        let decoded = try JSONDecoder().decode(DriveEditSession.self, from: JSONSerialization.data(withJSONObject: record))
        #expect(decoded.id == session.id && decoded.sentHash == "old-md5" && decoded.state == .conflict)
        let canonical = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(canonical["sentMD5"] == nil && canonical["sentHash"] as? String == "old-md5")
    }

    @Test(arguments: ["editing", "saving", "saved", "conflict", "unsent"])
    func readsLegacyDropboxStates(_ legacy: String) throws {
        let operation = UUID()
        var session = DropboxEditStore.Session(
            id: UUID(), localURL: URL(fileURLWithPath: "/tmp/edit"),
            file: DropboxItem(id: "id:opaque", name: "notes", path: "/notes", rev: "rev"), sentHash: "dropbox-hash")
        session.uploadOperation = operation
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        record["state"] = legacy
        let decoded = try JSONDecoder().decode(DropboxEditStore.Session.self, from: JSONSerialization.data(withJSONObject: record))
        let expected: CloudEditState
        switch legacy {
        case "editing": expected = .editing
        case "saving": expected = .saving
        case "saved": expected = .saved
        case "conflict": expected = .conflict
        default: expected = .unsent("Saved changes have not reached the cloud.")
        }
        #expect(decoded.id == session.id && decoded.state == expected && decoded.uploadOperation == operation)
        #expect(decoded.sentHash == session.sentHash && decoded.file.rev == "rev")
    }
}
