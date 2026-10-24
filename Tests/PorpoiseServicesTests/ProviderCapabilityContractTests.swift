import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// One operation contract, including destructive/conflict assertions, for every location. Each invocation owns
/// its filesystem/server. SMB exercises the mounted-local boundary, not the macOS SMB implementation.
@Suite(.serialized) struct ProviderCapabilityContractTests {
    @Test(arguments: [ProviderLocation.ftp, .sftp])
    func directProviderCopyRefusesAnOccupiedFileOrFolder(_ location: ProviderLocation) async throws {
        let fixture = try ProviderContractFixture(location); defer { fixture.close() }
        let source = try Scratch(), downloads = try Scratch()
        try await offThePool {
            let copy = try #require(fixture.copy)
            let local = try source.file("same.txt", "source")
            try fixture.upload(local, fixture.root)
            try fixture.makeFolder("target", fixture.root)
            let destination = try fixture.child("target", in: fixture.root).url
            let remote = try fixture.child("same.txt", in: fixture.root).url
            try copy(remote, destination)
            try Data("different".utf8).write(to: local)
            try fixture.makeFolder("other", fixture.root)
            let other = try fixture.child("other", in: fixture.root).url
            try fixture.upload(local, other)
            let replacement = try fixture.child("same.txt", in: other).url
            #expect(throws: (any Error).self) { try copy(replacement, destination) }
            let kept = try fixture.child("same.txt", in: destination).url
            #expect(try String(contentsOf: fixture.download(kept, downloads.url), encoding: .utf8) == "source")
            // An existing directory must not silently absorb the source's children either.
            #expect(throws: (any Error).self) { try copy(other, fixture.root) }
        }
    }

    @Test func driveUploadsNestedFoldersWithoutFollowingAncestorCycles() async throws {
        let fixture = try ProviderContractFixture(.drive); defer { fixture.close() }
        let source = try Scratch(), destination = try Scratch()
        let folder = try source.folder("upload tree")
        try source.file("upload tree/top.txt", "top bytes")
        try source.file("upload tree/nested/deep.txt", "nested bytes ü")
        try source.folder("upload tree/empty")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("loop").path, withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("nested/back").path, withDestinationPath: "..")
        try await offThePool {
            try fixture.upload(folder, fixture.root)
            let uploaded = try fixture.child(folder.lastPathComponent, in: fixture.root)
            #expect(uploaded.isDirectory)
            #expect(try fixture.list(uploaded.url).map(\.name).sorted() == ["empty", "nested", "top.txt"])
            let nested = try fixture.child("nested", in: uploaded.url)
            #expect(try fixture.list(nested.url).map(\.name) == ["deep.txt"])
            let top = try fixture.child("top.txt", in: uploaded.url), deep = try fixture.child("deep.txt", in: nested.url)
            #expect(try String(contentsOf: fixture.download(top.url, destination.url), encoding: .utf8) == "top bytes")
            #expect(try String(contentsOf: fixture.download(deep.url, destination.url), encoding: .utf8) == "nested bytes ü")
            let empty = try fixture.child("empty", in: uploaded.url)
            #expect(try fixture.list(empty.url).isEmpty)
        }
    }

    @Test(arguments: ProviderLocation.allCases)
    func operations(_ location: ProviderLocation) async throws {
        let fixture = try ProviderContractFixture(location)
        defer { fixture.close() }
        try await offThePool {
            let source = try Scratch(), destination = try Scratch()
            let payload = "contract bytes: ü + [1]"
            let file = try source.file("contract ü.txt", payload)
            try fixture.upload(file, fixture.root)
            let original = try fixture.child("contract ü.txt", in: fixture.root)
            #expect(!original.isDirectory)
            let downloaded = try fixture.download(original.url, destination.url)
            #expect(try String(contentsOf: downloaded, encoding: .utf8) == payload)
            #expect(throws: (any Error).self) { try fixture.download(original.url, destination.url) }
            #expect(try String(contentsOf: downloaded, encoding: .utf8) == payload)

            try fixture.rename(original.url, "renamed.txt")
            #expect(try !fixture.list(fixture.root).contains { $0.name == original.name })
            let renamed = try fixture.child("renamed.txt", in: fixture.root)
            try fixture.makeFolder("contract target", fixture.root)
            let folder = try fixture.child("contract target", in: fixture.root)
            try fixture.move(renamed.url, folder.url)
            #expect(try !fixture.list(fixture.root).contains { $0.name == renamed.name })
            let moved = try fixture.child(renamed.name, in: folder.url)
            let movedDownloads = try Scratch()
            #expect(try String(contentsOf: fixture.download(moved.url, movedDownloads.url), encoding: .utf8) == payload)
            if location != .drive {
                let incoming = try source.file(renamed.name, "incoming must survive")
                try fixture.upload(incoming, fixture.root)
                let incomingItem = try fixture.child(renamed.name, in: fixture.root)
                // Local jobs resolve the conflict by skipping; provider calls refuse it. Both must preserve bytes.
                do { try fixture.move(incomingItem.url, folder.url) } catch {}
                let remaining = try fixture.list(fixture.root)
                #expect(remaining.contains { $0.name == incomingItem.name })
                let check = try Scratch()
                #expect(try String(contentsOf: fixture.download(moved.url, check.url), encoding: .utf8) == payload)
                let sourceCheck = try Scratch()
                #expect(try String(contentsOf: fixture.download(incomingItem.url, sourceCheck.url), encoding: .utf8) == "incoming must survive")
                try fixture.delete(incomingItem.url)
            }

            // Download conflicts and rename conflicts are checked separately: a thrown unrelated error must not
            // count as protection. Verify both source and destination survive unchanged.
            let other = try source.file("occupied.txt", "keep me")
            try fixture.upload(other, folder.url)
            if location != .drive {  // Drive deliberately supports duplicate names.
                #expect(throws: (any Error).self) { try fixture.rename(moved.url, other.lastPathComponent) }
                let preserved = try fixture.child(moved.name, in: folder.url)
                let check = try Scratch()
                #expect(try String(contentsOf: fixture.download(preserved.url, check.url), encoding: .utf8) == payload)
            }
            let occupied = try fixture.child(other.lastPathComponent, in: folder.url)
            let check = try Scratch()
            #expect(try String(contentsOf: fixture.download(occupied.url, check.url), encoding: .utf8) == "keep me")
            if location == .drive {
                try fixture.rename(moved.url, occupied.name)
                #expect(try fixture.list(folder.url).filter { $0.name == occupied.name }.count == 2)
            }
            try fixture.delete(moved.url)
            #expect(try !fixture.list(folder.url).contains { $0.name == moved.name })
            try fixture.delete(occupied.url)
            try fixture.delete(folder.url)
            #expect(try !fixture.list(fixture.root).contains { $0.name == folder.name })
        }
    }

    @Test(arguments: ProviderLocation.allCases)
    func capabilitiesAreCompleteAndExplainExceptions(_ location: ProviderLocation) {
        for capability in ProviderLocation.Capability.allCases {
            switch location.support(capability) {
            case .supported: break
            case .unavailable(let explanation), .systemManaged(let explanation):
                #expect(!explanation.isEmpty)
                if capability != .operations && capability != .conflicts { #expect(location.help.contains(explanation)) }
            }
        }
        #expect(!location.title.isEmpty && !location.help.isEmpty)
    }

    @Test(arguments: ProviderLocation.allCases)
    func pagination(_ location: ProviderLocation) async throws {
        guard location.support(.pagination) == .supported else { return }
        let fixture = try ProviderContractFixture(location); defer { fixture.close() }
        try await fixture.preparePagination?()
        let count = try #require(fixture.requestCount)
        let source = try Scratch()
        let names = (0..<5).map { "page-contract-\($0).txt" }
        try await offThePool {
            for name in names { try fixture.upload(source.file(name, name), fixture.root) }
        }
        let before = try await count()
        let rows = try await offThePool { try fixture.list(fixture.root) }
        #expect(Set(names).isSubset(of: Set(rows.map(\.name))))
        #expect(Set(rows.map(\.url)).count == rows.count)
        #expect(try await count() - before >= 3, "Five new files must require at least three two-item pages")
    }

    @Test(arguments: ProviderLocation.allCases)
    func quota(_ location: ProviderLocation) async throws {
        guard location.support(.quota) == .supported else { return }
        let fixture = try ProviderContractFixture(location); defer { fixture.close() }
        let read = try #require(fixture.quota)
        let (used, total) = try await read()
        #expect(used == 123 && total == 456)
    }

    @Test(arguments: ProviderLocation.allCases)
    func expiry(_ location: ProviderLocation) async throws {
        guard location.support(.expiry) == .supported else { return }
        let fixture = try ProviderContractFixture(location); defer { fixture.close() }
        let expire = try #require(fixture.expire)
        try await expire()
        // A cached token deliberately accepted with a one-second lifetime must be refreshed before this request.
        #expect(try await offThePool { try !fixture.list(fixture.root).isEmpty })
    }

    @Test(arguments: ProviderLocation.allCases)
    func reconnect(_ location: ProviderLocation) async throws {
        guard location.support(.reconnect) == .supported else { return }
        let fixture = try ProviderContractFixture(location); defer { fixture.close() }
        let outage = try #require(fixture.outage)
        let before = try await offThePool { try fixture.list(fixture.root).map(\.name).sorted() }
        try await outage(true)
        if let isOffline = fixture.isOffline {
            let cached = try await offThePool { try fixture.list(fixture.root).map(\.name).sorted() }
            #expect(cached == before)
            #expect(isOffline())
        } else {
            await #expect(throws: (any Error).self) { try await offThePool { try fixture.list(fixture.root) } }
        }
        try await outage(false)
        #expect(try await offThePool { try fixture.list(fixture.root).map(\.name).sorted() } == before)
        if let isOffline = fixture.isOffline { #expect(!isOffline()) }
        let source = try Scratch(), file = try source.file("after-reconnect.txt", "online again")
        try await offThePool {
            try fixture.upload(file, fixture.root)
            #expect(try fixture.list(fixture.root).contains { $0.name == file.lastPathComponent })
        }
    }
}

/// Only adapts APIs and owns fixture lifetime; all assertions live in the shared suite above.
private final class ProviderContractFixture {
    let root: URL
    let list: (URL) throws -> [FileItem]
    let upload: (URL, URL) throws -> Void
    let download: (URL, URL) throws -> URL
    let rename: (URL, String) throws -> Void
    var copy: ((URL, URL) throws -> Void)?
    let move: (URL, URL) throws -> Void
    let delete: (URL) throws -> Void
    let makeFolder: (String, URL) throws -> Void
    let close: () -> Void
    var preparePagination: (() async throws -> Void)?
    var requestCount: (() async throws -> Int)?
    var quota: (() async throws -> (Int64?, Int64?))?
    var expire: (() async throws -> Void)?
    var outage: ((Bool) async throws -> Void)?
    var isOffline: (() -> Bool)?

    init(_ location: ProviderLocation) throws {
        if location == .local || location == .smb {
            let scratch = try Scratch()
            if location == .smb {
                root = try #require(
                    NetworkMounts.path(
                        of: URL(string: "smb://fixture/share/")!, onVolume: scratch.url,
                        mountedFrom: URL(string: "smb://fixture/share")!))
            } else {
                root = scratch.url
            }
            list = { try DirectoryLister.list($0) }
            upload = { source, folder in
                let job = FileJob(kind: .copy, sources: [source], destinationFolder: folder)
                _ = try job.run(); if let error = job.firstError { throw error }
            }
            download = { source, folder in
                let target = folder.appendingPathComponent(source.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: target.path) else { throw RemoteError.exists(source.lastPathComponent) }
                let job = FileJob(kind: .copy, sources: [source], destinationFolder: folder)
                _ = try job.run(); if let error = job.firstError { throw error }; return target
            }
            rename = { _ = try FileActions.rename($0, to: $1) }
            makeFolder = { _ = try FileActions.makeFolder(named: $0, in: $1) }
            move = { source, folder in
                let job = FileJob(kind: .move, sources: [source], destinationFolder: folder)
                _ = try job.run(); if let error = job.firstError { throw error }
            }
            delete = { source in
                let job = FileJob(kind: .delete, sources: [source]); _ = try job.run()
                if let error = job.firstError { throw error }
            }
            close = { _ = scratch }
            return
        }
        let provider: RemoteProvider
        let keepAlive: AnyObject
        let offline = Locked(false)
        let send: CloudHTTPTransport.Send = { request in
            if offline.value { throw URLError(.notConnectedToInternet) }
            let (bytes, response) = try await CloudHTTPTransport.unredirected.data(for: request)
            return (bytes, try #require(response as? HTTPURLResponse))
        }
        let http = CloudHTTPTransport(send: send)
        outage = { value in offline.change { $0 = value } }
        let expired = CloudOAuthToken(access_token: "expired-contract", expires_in: 1, refresh_token: nil, token_type: "Bearer")
        var cleanup: () -> Void = {}
        var createFolder: ((String, URL) throws -> Void)?
        var confirmedDelete: ((URL) throws -> Void)?
        switch location {
        case .drive:
            let server = try FakeDriveServer(fixture: FakeDriveServer.fixture("mutations.json"))
            let (initial, tokens, _) = try server.client()
            let client = DriveClient(
                accountID: initial.accountID, tokens: tokens, http: DriveHTTP(send: send),
                baseURL: server.base.appendingPathComponent("drive/v3/"), mutationJournal: .init(folder: server.scratch.url))
            root = DriveLocation(accountID: client.accountID).url
            provider = DriveProvider(accountID: client.accountID, client: client); keepAlive = server
            preparePagination = { try await server.control(["listPageSize": 2]) }
            requestCount = { try await (server.stats()["requests"] as? [String] ?? []).count }
            quota = {
                try await server.control(["about": ["storageQuota": ["usage": "123", "limit": "456"]]])
                let info = try await client.accountInfo(); return (info.storageUsed, info.storageLimit)
            }
            expire = { try await tokens.accept(expired) }
            isOffline = { client.isOffline }
            createFolder = { name, folder in
                _ = try CloudAwait.run { try await client.createFolder(name: name, parentID: "root") }; _ = folder
            }
        case .dropbox:
            let server = try FakeDropboxServer(), initial = try server.client()
            let client = DropboxClient(
                accountID: initial.accountID, configuration: server.config, tokens: initial.tokens, directory: server.directory, http: http)
            root = DropboxLocation(accountID: client.accountID).url
            provider = DropboxProvider(client: client); keepAlive = server
            requestCount = { try await server.requests().count }
            quota = {
                try await server.configure(["spaceUsage": ["used": 123, "allocation": [".tag": "individual", "allocated": 456]]])
                let value = try await client.spaceUsage(); return (value.used, value.total)
            }
            expire = { try await client.tokens.accept(expired) }
            isOffline = { client.isOffline }
            createFolder = { name, _ in _ = try CloudAwait.run { try await client.createFolder(name: name) } }
            confirmedDelete = { url in
                let id = try #require(DropboxLocation(url: url)).itemID
                _ = try CloudAwait.run { try await client.delete(client.metadata(id), confirmedWithoutUndo: true) }
            }
        case .oneDrive:
            let server = try FakeGraphServer(), initial = try server.client()
            let client = OneDriveClient(
                accountID: initial.accountID, configuration: server.config, tokens: initial.tokens, driveID: initial.driveID,
                directory: server.directory, http: http, retryWait: { _ in })
            root = OneDriveLocation(accountID: client.accountID, driveID: client.driveID).url
            provider = OneDriveProvider(client: client); keepAlive = server
            requestCount = { try await server.requests().count }
            quota = {
                try await server.configure(["quota": ["used": 123, "total": 456]])
                let value = try await client.quota(); return (value.used, value.total)
            }
            expire = { try await client.tokens.accept(expired) }
            isOffline = { client.isOffline }
            createFolder = { name, _ in _ = try CloudAwait.run { try await client.createFolder(name: name) } }
            confirmedDelete = { url in
                let id = try #require(OneDriveLocation(url: url)).itemID
                _ = try CloudAwait.run { try await client.delete(client.metadata(id), confirmedWithoutUndo: true) }
            }
        case .box:
            let server = try FakeBoxServer(), client = try server.client(http: http, retryWait: { _ in })
            root = BoxLocation(accountID: client.accountID).url
            provider = BoxProvider(client: client); keepAlive = server
            requestCount = { try await server.requests().count }
            quota = {
                try await server.configure(["quota": ["space_used": 123, "space_amount": 456]])
                let value = try await client.quota(); return (value.used, value.total)
            }
            expire = { try await client.tokens.accept(expired) }
            isOffline = { client.isOffline }
            createFolder = { name, _ in _ = try CloudAwait.run { try await client.createFolder(name: name) } }
        case .s3:
            let server = try LocalFixtureServer(script: TestPaths.script("fake-s3-server.py"))
            let location = S3Location(bucket: "fixture", endpoint: server.base, accountID: UUID())
            try S3Credentials.save(.init(accessKeyID: "fixture-access", secretAccessKey: "fixture-secret"), accountID: location.accountID)
            root = location.url
            provider = S3Provider(client: S3Client(location: location, directory: server.scratch.url, transport: http)); keepAlive = server
            requestCount = {
                let bytes = try await URLSession.shared.data(from: server.base.appendingPathComponent("stats")).0
                let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                return (json["requests"] as? [[String: Any]] ?? []).count
            }
            cleanup = { try? S3Credentials.remove(accountID: location.accountID) }
        case .ftp:
            let server = try LocalFixtureServer(script: TestPaths.script("fake-ftp-server.py"))
            root = URL(string: "ftp://127.0.0.1:\(server.base.port!)/")!
            provider = FTPProvider(url: root, credentialStore: MemoryCredentials(), reconnect: .never); keepAlive = server
            outage = { value in
                if value { try server.scratch.file("offline", "") } else { try FileManager.default.removeItem(at: server.scratch.path("offline")) }
            }
        case .sftp:
            let server = try SSHServer()
            root = server.url(try server.folder().path, isDirectory: true)
            let ssh = server.provider(); provider = ssh; keepAlive = server
            outage = { value in
                if value { server.killAbruptly(); ssh.retire() } else { try server.start() }
            }
        case .local, .smb: preconditionFailure("handled above")
        }
        list = provider.list
        upload = provider.upload
        download = provider.download
        rename = provider.rename
        copy = { try provider.copy([$0], into: $1) }
        move = { try provider.move([$0], into: $1) }
        delete = confirmedDelete ?? { try provider.delete([$0]) }
        makeFolder = createFolder ?? { name, folder in try provider.makeFolder(folder.appendingPathComponent(name, isDirectory: true)) }
        close = {
            if let server = keepAlive as? SSHServer { server.stop() }
            cleanup()
            _ = keepAlive
        }
    }

    func child(_ name: String, in folder: URL) throws -> FileItem {
        try #require(list(folder).first { $0.name == name })
    }
}
