import Foundation

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
}
