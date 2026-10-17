import Foundation
import PorpoiseCore

/// Routes the existing cloud contracts by descriptor/account. Views never select a provider implementation.
public final class CompositeCloudBackend: CloudBackend {
    public var onChange: (() -> Void)?
    public let backends: [CloudProvider: CloudBackend]
    public init(_ backends: [CloudProvider: CloudBackend]) {
        self.backends = backends
        for backend in backends.values { backend.onChange = { [weak self] in self?.onChange?() } }
    }
    public var accounts: [CloudAccount] { CloudProvider.allCases.flatMap { backends[$0]?.accounts ?? [] } }
    private func backend(_ id: String) -> CloudBackend? { backends.values.first { $0.accounts.contains { $0.id == id } } }
    private func backend(_ url: URL) -> CloudBackend? { CloudProviderDescriptor.descriptor(for: url).flatMap { backends[$0.provider] } }
    public func connect(
        _ provider: CloudProvider, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<CloudAccount, CloudConnectError>) -> Void
    ) -> () -> Void {
        guard let backend = backends[provider] else { done(.failure(.failed("This provider is not available."))); return {} }
        return backend.connect(provider, openBrowser: openBrowser, done: done)
    }
    public func signInAgain(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void) -> () ->
        Void
    {
        guard let backend = backend(id) else { done(.failure(.failed("This account is no longer connected."))); return {} }
        return backend.signInAgain(id, openBrowser: openBrowser, done: done)
    }
    public func requestWriteAccess(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void) -> (
    ) -> Void {
        guard let backend = backend(id) else { done(.failure(.failed("This account is no longer connected."))); return {} }
        return backend.requestWriteAccess(id, openBrowser: openBrowser, done: done)
    }
    public func remove(_ id: String, done: @escaping (Error?) -> Void) {
        guard let backend = backend(id) else { done(nil); return }; backend.remove(id, done: done)
    }
    public func url(_ id: String, root: CloudRoot) -> URL { backend(id)?.url(id, root: root) ?? URL(string: "cloud-disconnected:///")! }
    public func accountID(for url: URL) -> String? { backend(url)?.accountID(for: url) }
    public func info(for url: URL) -> CloudItemInfo? { backend(url)?.info(for: url) }
    public func ancestors(of url: URL) -> [URL] { backend(url)?.ancestors(of: url) ?? [] }
    public func permissions(for url: URL) -> CloudPermissions? { backend(url)?.permissions(for: url) }
    public func content(for accountID: String) -> CloudContentSource? { backend(accountID)?.content(for: accountID) }
    public func content(for url: URL) -> CloudContentSource? { backend(url)?.content(for: url) }
    public func savedAt(for folder: URL) -> Date? { backend(folder)?.savedAt(for: folder) }
    public func avatar(_ id: String, done: @escaping (Data?) -> Void) {
        guard let backend = backend(id) else { done(nil); return }; backend.avatar(id, done: done)
    }
    public func resolveLink(_ text: String, done: @escaping (CloudLinkResult) -> Void) {
        // Link recognition remains a provider capability; an unsupported link has no side effect.
        let values = Array(backends.values)
        func next(_ index: Int) {
            guard index < values.count else { done(.notALink); return }
            values[index].resolveLink(text) { result in if result == .notALink { next(index + 1) } else { done(result) } }
        }
        next(0)
    }
    public func createFolder(named name: String, in folder: URL, done: @escaping (Result<FileItem, Error>) -> Void) {
        guard let backend = backend(folder) else { done(.failure(CloudEditError.notSupported)); return };
        backend.createFolder(named: name, in: folder, done: done)
    }
    public func rename(_ url: URL, to name: String, done: @escaping (Result<FileItem, Error>) -> Void) {
        guard let backend = backend(url) else { done(.failure(CloudEditError.notSupported)); return }; backend.rename(url, to: name, done: done)
    }
    public func trash(_ urls: [URL], done: @escaping ([URL], Error?) -> Void) {
        guard let first = urls.first, let backend = backend(first), urls.allSatisfy({ self.backend($0) === backend }) else {
            done([], CloudEditError.notSupported); return
        }
        backend.trash(urls, done: done)
    }
    public func untrash(_ urls: [URL], done: @escaping ([URL], Error?) -> Void) {
        guard let first = urls.first, let backend = backend(first), urls.allSatisfy({ self.backend($0) === backend }) else {
            done([], CloudEditError.notSupported); return
        }
        backend.untrash(urls, done: done)
    }
    public func search(
        _ text: String, in folder: URL, everywhere: Bool, contents: Bool, pageToken: String?, done: @escaping (Result<CloudSearchPage, Error>) -> Void
    ) -> () -> Void {
        guard let backend = backend(folder) else { done(.failure(CloudEditError.notSupported)); return {} }
        return backend.search(text, in: folder, everywhere: everywhere, contents: contents, pageToken: pageToken, done: done)
    }
    public func checkForChanges(_ id: String?) {
        if let id { backend(id)?.checkForChanges(id) } else { backends.values.forEach { $0.checkForChanges(nil) } }
    }
    public func setActive(_ active: Bool) { backends.values.forEach { $0.setActive(active) } }
}
