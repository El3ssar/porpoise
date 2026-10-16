import Foundation
import PorpoiseCore
import PorpoiseServices

/// Test-only subprocess for process-death proofs. Its credential store accepts fixture data only.
final class FixtureCredentials: DriveCredentialStore, @unchecked Sendable {
    let folder: URL
    init(folder: URL) { self.folder = folder }
    func url(_ clientID: String, _ accountID: UUID) -> URL {
        folder.appendingPathComponent(clientID + "-" + accountID.uuidString)
    }
    func read(clientID: String, accountID: UUID) throws -> String? {
        let file = url(clientID, accountID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }
    func save(_ token: String, clientID: String, accountID: UUID) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(token.utf8).write(to: url(clientID, accountID), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(clientID, accountID).path)
    }
    func remove(clientID: String, accountID: UUID) throws {
        let file = url(clientID, accountID)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

let args = CommandLine.arguments
// Refuse production endpoints or arbitrary scopes. This binary has no Keychain implementation.
guard args.count == 8, let base = URL(string: args[1]), base.scheme == "http", base.host == "127.0.0.1",
    let accountID = UUID(uuidString: args[3]), let operationID = UUID(uuidString: args[4])
else { exit(64) }
let journalFolder = URL(fileURLWithPath: args[2])
let credentials = FixtureCredentials(folder: journalFolder.appendingPathComponent("FixtureCredentials"))
let config = DriveOAuthConfiguration(clientID: "fixture-client", tokenURL: base.appendingPathComponent("token"))
try credentials.save("fixture-refresh", clientID: config.clientID, accountID: accountID)
let mode = args[5]
let http = DriveHTTP { request in
    let mutation = request.httpMethod == "POST" && (request.url?.path == "/drive/v3/files" || request.url?.path == "/upload/drive/v3/files")
    if mutation, mode == "before" { _exit(91) }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw DriveError.invalidResponse }
    if mutation, mode == "after" { _exit(92) }
    if request.httpMethod == "PUT", mode == "chunk", response.statusCode == 308 { _exit(93) }
    if request.httpMethod == "PUT", mode == "commit", response.statusCode == 200 { _exit(94) }
    return (data, response)
}
let manager = DriveTokenManager(configuration: config, accountID: accountID, credentials: credentials, http: http)
let client = DriveClient(
    accountID: accountID, tokens: manager, http: http, baseURL: base.appendingPathComponent("drive/v3/"),
    mutationJournal: .init(folder: journalFolder), metadataDirectory: journalFolder.appendingPathComponent("Metadata"))
do {
    let result: DriveFile
    if args[6] == "edit" {
        let session = try await client.edits.open(client.file(args[7]))
        try Data("durable edit after kill".utf8).write(to: session.localURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: session.localURL)
        try handle.synchronize(); try handle.close()
        kill(getpid(), SIGKILL)
        _exit(95)
    } else if args[6] == "folder" {
        result = try await client.createFolder(name: args[7], parentID: "root", operationID: operationID)
    } else {
        result = try await client.upload(URL(fileURLWithPath: args[7]), parentID: "root", operationID: operationID)
    }
    print(result.id)
} catch {
    // Never print provider bodies or session URLs.
    exit(1)
}
