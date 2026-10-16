import Foundation
import PorpoiseCore

/// A cloud backend with made-up accounts and no network, for test instances (PORPOISE_CLOUD_DEMO) and tests. A sign-in
/// waits until `finishSignIn` is called, as if the user were in the browser.
public final class DemoCloudBackend: CloudBackend {
    public private(set) var accounts: [CloudAccount] = []
    public var onChange: (() -> Void)?
    /// The pending sign-in's completion.
    private var pending: ((Result<CloudAccount, CloudConnectError>) -> Void)?
    private var pendingAgain: (id: String, done: (Result<Void, CloudConnectError>) -> Void)?
    /// Pictures by account id.
    public var avatars: [String: Data] = [:]
    public var infos: [URL: CloudItemInfo] = [:]
    public var links: [String: CloudLinkResult] = [:]
    /// When each folder's listing was last read (the offline message's time).
    public var savedDates: [URL: Date] = [:]
    /// What a search answers, page by page (nil: searching isn't supported); `searchError` fails the next page asked for.
    public var searchPages: [[FileItem]]?
    public var searchError: Error?
    /// Searches asked for: text, folder, everywhere, contents and the page token.
    public private(set) var searches: [(text: String, folder: URL, everywhere: Bool, contents: Bool, page: String?)] = []
    /// Holds pages back until `answerSearch` (a slow service); otherwise they answer at once.
    public var holdsSearches = false
    private var heldSearch: (() -> Void)?
    /// Browser addresses handed out (tests check them; nothing is opened).
    public private(set) var browserRequests: [URL] = []

    public init(accounts: [CloudAccount] = []) { self.accounts = accounts }

    public var isSigningIn: Bool { pending != nil || pendingAgain != nil }

    public func connect(
        _ provider: CloudProvider, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
    ) -> () -> Void {
        let u = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?demo=1")!
        browserRequests.append(u)
        pending = done
        return { [weak self] in self?.pending = nil }
    }

    /// Ends the sign-in in progress: with this account (nil: the user closed the browser).
    public func finishSignIn(_ account: CloudAccount?) {
        if let again = pendingAgain {
            pendingAgain = nil
            if let i = accounts.firstIndex(where: { $0.id == again.id }) { accounts[i].status = .ok }
            again.done(account == nil ? .failure(.cancelled) : .success(()))
            onChange?()
            return
        }
        guard let done = pending else { return }
        pending = nil
        guard let account else { done(.failure(.cancelled)); return }
        if let known = accounts.first(where: { $0.email.lowercased() == account.email.lowercased() }) {
            done(.failure(.alreadyConnected(known)))
            return
        }
        accounts.append(account)
        onChange?()
        done(.success(account))
    }

    public func failSignIn(_ message: String) {
        pending?(.failure(.failed(message)))
        pending = nil
    }

    public func signInAgain(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void)
        -> () -> Void
    {
        browserRequests.append(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?demo=1&login_hint=\(id)")!)
        pendingAgain = (id, done)
        return { [weak self] in self?.pendingAgain = nil }
    }

    public func setStatus(_ id: String, _ status: CloudAccount.Status) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].status = status
        onChange?()
    }

    public func remove(_ id: String, done: @escaping (Error?) -> Void) {
        accounts.removeAll { $0.id == id }
        onChange?()
        done(nil)
    }

    public func url(_ id: String, root: CloudRoot) -> URL {
        let path: String
        switch root {
        case .myDrive: path = "my-drive"
        case .sharedWithMe: path = "shared-with-me"
        case .sharedDrives: path = "shared-drives"
        }
        return URL(string: "gdrive://\(id)/\(path)")!
    }

    public func accountID(for url: URL) -> String? { url.host }

    public func info(for url: URL) -> CloudItemInfo? { infos[url] }

    public func resolveLink(_ text: String, done: @escaping (CloudLinkResult) -> Void) { done(links[text] ?? .noAccess) }

    public func avatar(_ id: String, done: @escaping (Data?) -> Void) { done(avatars[id]) }

    // MARK: Changes, kept in memory

    /// Permissions by location; unknown locations may be changed.
    public var permissionsByURL: [URL: CloudPermissions] = [:]
    /// What has been changed, for tests: trashed items and new names.
    public private(set) var trashed: Set<URL> = []
    public private(set) var names: [URL: String] = [:]
    public private(set) var createdFolders: [URL] = []
    /// The next change fails with this (once).
    public var failNext: Error?
    /// Changes answer only when `finishChanges` is called (to look at the optimistic state in between).
    public var holdsChanges = false
    private var held: [() -> Void] = []

    public func finishChanges() {
        let h = held
        held = []
        h.forEach { $0() }
    }

    private func answer(_ work: @escaping () -> Void) {
        if holdsChanges { held.append(work) } else { work() }
    }

    private func failure() -> Error? {
        defer { failNext = nil }
        return failNext
    }

    public func setCanWrite(_ id: String, _ on: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].canWrite = on
        onChange?()
    }

    public func permissions(for url: URL) -> CloudPermissions? { permissionsByURL[url] }

    public func requestWriteAccess(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void)
        -> () -> Void
    {
        browserRequests.append(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?demo=1&scope=drive&login_hint=\(id)")!)
        pendingAgain = (
            id,
            { [weak self] result in
                if case .success = result { self?.setCanWrite(id, true) }
                done(result)
            }
        )
        return { [weak self] in self?.pendingAgain = nil }
    }

    public func createFolder(named name: String, in folder: URL, done: @escaping (Result<FileItem, Error>) -> Void) {
        answer { [self] in
            if let e = failure() { done(.failure(e)); return }
            let u = folder.appendingPathComponent("new\(createdFolders.count + 1)", isDirectory: true)
            createdFolders.append(u)
            names[u] = name
            done(.success(FileItem(url: u, name: name, isDirectory: true, modificationDate: Date())))
        }
    }

    public func rename(_ url: URL, to name: String, done: @escaping (Result<FileItem, Error>) -> Void) {
        answer { [self] in
            if let e = failure() { done(.failure(e)); return }
            names[url] = name
            done(.success(FileItem(url: url, name: name, isDirectory: url.hasDirectoryPath)))
        }
    }

    public func trash(_ urls: [URL], done: @escaping (_ trashed: [URL], _ error: Error?) -> Void) {
        answer { [self] in
            if let e = failure() { done([], e); return }
            trashed.formUnion(urls)
            done(urls, nil)
        }
    }

    public func untrash(_ urls: [URL], done: @escaping (_ restored: [URL], _ error: Error?) -> Void) {
        answer { [self] in
            if let e = failure() { done([], e); return }
            trashed.subtract(urls)
            done(urls, nil)
        }
    }
}

extension DemoCloudBackend {
    public func savedAt(for folder: URL) -> Date? { savedDates[folder] }

    public func search(
        _ text: String, in folder: URL, everywhere: Bool, contents: Bool, pageToken: String?,
        done: @escaping (Result<CloudSearchPage, Error>) -> Void
    ) -> () -> Void {
        searches.append((text, folder, everywhere, contents, pageToken))
        var cancelled = false
        let answer = { [weak self] in
            guard let self, !cancelled else { return }
            if let error = self.searchError {
                self.searchError = nil
                return done(.failure(error))
            }
            guard let pages = self.searchPages else { return done(.failure(CloudEditError.notSupported)) }
            let index = pageToken.flatMap(Int.init) ?? 0
            let items = index < pages.count ? pages[index] : []
            done(.success(CloudSearchPage(items: items, nextPageToken: index + 1 < pages.count ? String(index + 1) : nil)))
        }
        if holdsSearches { heldSearch = answer } else { answer() }
        return { cancelled = true }
    }

    /// Answers the page held back (`holdsSearches`).
    public func answerSearch() {
        let held = heldSearch
        heldSearch = nil
        held?()
    }
}
