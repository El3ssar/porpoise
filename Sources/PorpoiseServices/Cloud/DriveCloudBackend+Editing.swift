import Foundation
import PorpoiseCore

/// Google Drive changes for the app: Drive's per-item capabilities as permissions, and the provider's mutations with
/// their answers on the main queue. The provider rechecks capabilities and scope before each request.
extension DriveCloudBackend {
    private func drive(_ url: URL) -> DriveProvider? { RemoteFS.provider(for: url) as? DriveProvider }

    public func permissions(for url: URL) -> CloudPermissions? {
        guard let location = DriveLocation(url: url) else { return nil }
        switch location.collection {
        case .sharedWithMe: return CloudPermissions(collection: .sharedWithMe)
        case .sharedDrives: return CloudPermissions(collection: .sharedDrives)
        case .myDrive, .folder: break
        }
        guard let drive = drive(url), let ops = drive.capabilities(for: url) else { return nil }
        let file = drive.metadata(for: url)
        let me = MainActor.assumeIsolated { store.accounts.first { $0.id == location.accountID }?.email.lowercased() }
        let access = Self.access(ops.role) ?? file.flatMap { Self.info($0, me: me).access }
        return CloudPermissions(
            canAddChildren: ops.canAddChildren, canRename: ops.canRename, canTrash: ops.canTrash, canMove: ops.canMove,
            // Copying out is a download or an export: folders are copied item by item.
            canCopy: ops.canCopy || ops.canDownload || ops.canExport || ops.canBrowse, access: access,
            collection: location.collection == .myDrive ? .myDrive : nil, inSharedDrive: file?.driveId != nil,
            name: location.collection == .myDrive ? "My Drive" : file?.name)
    }

    /// The provider's error as the message bar says it; an old read-only grant brings up "Allow Changes…".
    static func editError(_ error: Error) -> Error {
        (error as? DriveError) == .needsWriteAccess ? CloudEditError.needsWriteAccess : error
    }

    private func run<T>(_ url: URL, _ work: @escaping (DriveProvider) async throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        guard let drive = drive(url) else { done(.failure(DriveError.reconnect)); return }
        Task { @MainActor in
            do { done(.success(try await work(drive))) } catch { done(.failure(Self.editError(error))) }
        }
    }

    public func createFolder(named name: String, in folder: URL, done: @escaping (Result<FileItem, Error>) -> Void) {
        run(folder, { try await $0.createFolder(named: name, in: folder) }, done: done)
    }

    public func rename(_ url: URL, to name: String, done: @escaping (Result<FileItem, Error>) -> Void) {
        run(url, { try await $0.rename(url, to: name) }, done: done)
    }

    public func trash(_ urls: [URL], done: @escaping (_ trashed: [URL], _ error: Error?) -> Void) {
        guard let first = urls.first, let drive = drive(first) else { done([], DriveError.reconnect); return }
        Task { @MainActor in
            let result = await drive.trash(urls)
            let failure = result.failures.values.first.map { CloudEditError.denied($0) as Error }
            done(result.trashed, failure)
        }
    }

    public func untrash(_ urls: [URL], done: @escaping (_ restored: [URL], _ error: Error?) -> Void) {
        run(urls.first ?? URL(string: "gdrive://x/")!, { try await $0.untrash(urls) }) { result in
            switch result {
            case .success: done(urls, nil)
            case .failure(let e): done([], e)
            }
        }
    }
}
