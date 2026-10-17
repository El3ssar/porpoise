import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct RemoteFolderTreeTests {
    @MainActor private func until(_ tree: RemoteFolderTree, _ ready: @escaping () -> Bool) async throws {
        if ready() { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            let timeout = DispatchWorkItem {
                guard !completed else { return }
                completed = true
                tree.onChange = nil
                continuation.resume(throwing: URLError(.timedOut))
            }
            tree.onChange = { _ in
                if !completed && ready() {
                    completed = true
                    timeout.cancel()
                    tree.onChange = nil
                    continuation.resume()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func driveUsesBrowserCacheAndKeepsNodeIdentityThroughRenameAndDelete() async throws {
        let server = try FakeDriveServer()
        let (client, _, _) = try server.client()
        let provider = DriveProvider(accountID: client.accountID, client: client)
        let root = DriveLocation(accountID: client.accountID).url
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let browserRows = try await provider.refresh(root)
        let tree = RemoteFolderTree(url: root)
        #expect(tree.root.children == nil && tree.root.isExpandable && !tree.root.isLoading)
        tree.root.expand()
        #expect(tree.root.children?.map(\.url) == browserRows.filter(\.isBrowsableFolder).sorted { $0.name < $1.name }.map(\.url))
        try await until(tree) { !tree.root.isLoading }
        let folder = try #require(tree.root.children?.first { $0.name == "Project Atlas" })
        #expect(folder.children == nil && folder.isExpandable)
        // Browser prefetch must stay off for tree nodes: unopened folders have not been listed.
        #expect(provider.cachedListing(folder.url) == nil)
        folder.expand()
        try await until(tree) { !folder.isLoading && folder.children != nil }
        #expect(folder.children?.isEmpty == true && !folder.isExpandable)
        #expect(provider.cachedListing(folder.url)?.count == 2)
        func change(_ file: [String: Any]) async throws {
            var request = URLRequest(url: server.base.appendingPathComponent("__control"))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["remoteChanges": [["fileId": "folder-a", "file": file]]])
            _ = try await URLSession.shared.data(for: request)
        }
        try await change(["name": "Renamed Atlas"])
        provider.invalidate(folder: root)
        NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: client.accountID.uuidString.lowercased())
        try await until(tree) { folder.name == "Renamed Atlas" && !tree.root.isLoading }
        #expect(tree.find(folder.url) === folder && folder.isExpanded)
        try await change(["trashed": true])
        provider.invalidate(folder: root)
        NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: client.accountID.uuidString.lowercased())
        try await until(tree) { tree.find(folder.url) == nil && !tree.root.isLoading }
        tree.root.collapse()
        var invalidated = false
        tree.onChange = { _ in invalidated = true }
        tree.reload()
        #expect(invalidated && tree.root.children == nil && tree.root.isExpandable && !tree.root.isLoading)
        tree.onChange = nil
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func dropboxLazyPagingChangesHiddenFoldersAndNamespaceIdentity() async throws {
        let server = try FakeDropboxServer()
        let client = try server.client(namespace: "team-root")
        let provider = DropboxProvider(client: client)
        let root = DropboxLocation(accountID: client.accountID, namespaceID: "team-root").url
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        let tree = RemoteFolderTree(url: root)
        #expect(tree.root.children == nil && tree.root.isExpandable)
        #expect(try await server.requests().isEmpty)
        tree.root.expand()
        #expect(tree.root.isLoading)
        try await until(tree) { !tree.root.isLoading && tree.root.children != nil }
        let folder = try #require(tree.root.children?.first { $0.name == "Folder" })
        #expect(DropboxLocation(url: folder.url)?.namespaceID == "team-root")
        #expect(folder.children == nil && provider.cachedListing(folder.url) == nil)
        let browser = DirectoryModel(location: root, prefetchFolders: false)
        browser.reload()
        #expect(browser.items == provider.cachedListing(root))
        folder.expand()
        try await until(tree) { !folder.isLoading && folder.children != nil }
        #expect(folder.children?.isEmpty == true)
        _ = try await client.createFolder(name: "Visible", parent: "/Folder")
        _ = try await client.createFolder(name: ".hidden", parent: "/Folder")
        FileOperationsController.notifyChanged([folder.url])
        try await until(tree) { folder.children?.map(\.name) == ["Visible"] && !folder.isLoading }
        tree.showHidden = true
        tree.reload()
        try await until(tree) { folder.children?.count == 2 && !folder.isLoading }
        let renamed = try await client.rename(client.metadata("id:folder"), to: "Renamed")
        NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: client.accountID.uuidString.lowercased())
        try await until(tree) { folder.name == "Renamed" && !tree.root.isLoading }
        #expect(tree.find(folder.url) === folder)
        _ = try await client.delete(renamed, confirmedWithoutUndo: true)
        NotificationCenter.default.post(name: CloudAccounts.remoteChanged, object: client.accountID.uuidString.lowercased())
        try await until(tree) { tree.find(folder.url) == nil && !tree.root.isLoading }
        let requests = try await server.requests()
        #expect(
            requests.allSatisfy { request in
                guard let header = request["namespace"] as? String,
                    let object = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String]
                else { return false }
                return object[".tag"] == "namespace_id" && object["namespace_id"] == "team-root"
            })
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func disconnectedRootFailsQuietlyAndRetriesOnExpand() async throws {
        let account = UUID()
        let root = DriveLocation(accountID: account).url
        let tree = RemoteFolderTree(url: root)
        tree.root.expand()
        try await until(tree) { !tree.root.isLoading && tree.root.message != nil }
        #expect(tree.root.children == nil && tree.root.isExpandable)
        let server = try FakeDriveServer()
        let (client, _, _) = try server.client(id: account)
        RemoteFS.registerDrive(DriveProvider(accountID: account, client: client), accountID: account)
        defer { RemoteFS.unregisterDrive(accountID: account) }
        tree.root.collapse()
        tree.root.expand()
        try await until(tree) { !tree.root.isLoading && tree.root.children != nil }
        #expect(tree.root.message == nil)
    }
}
