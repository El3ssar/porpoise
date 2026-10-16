import Foundation
import PorpoiseCore

/// A page of search results from a cloud service.
public struct CloudSearchPage: Sendable {
    public var items: [FileItem]
    public var nextPageToken: String?

    public init(items: [FileItem], nextPageToken: String? = nil) {
        self.items = items
        self.nextPageToken = nextPageToken
    }
}

// Services without a search of their own.
extension CloudBackend {
    public func search(
        _ text: String, in folder: URL, everywhere: Bool, contents: Bool, pageToken: String?,
        done: @escaping (Result<CloudSearchPage, Error>) -> Void
    ) -> () -> Void {
        done(.failure(CloudEditError.notSupported))
        return {}
    }
}

/// A search run by the cloud service (the search bar in a cloud folder): its pages are asked for one after another and
/// handed over as they come, the results growing, up to `limit`. Main queue only.
public final class CloudSearch {
    public let text: String
    public let folder: URL
    public let everywhere: Bool
    public let contents: Bool
    /// More results than this aren't asked for: the search should be narrowed instead.
    public let limit: Int
    public private(set) var items: [FileItem] = []
    public private(set) var isDone = false
    /// Stopped at `limit` while the service had more.
    public private(set) var isTruncated = false
    public private(set) var error: Error?
    /// `items` so far, and whether the search finished (all pages, the limit, or an error).
    public var onResults: ((_ items: [FileItem], _ done: Bool) -> Void)?

    private let accounts: CloudAccounts
    private var cancelPage: (() -> Void)?
    private var stopped = false
    private var seen: Set<URL> = []
    private var tokens: Set<String> = []

    public init(
        _ text: String, in folder: URL, everywhere: Bool = false, contents: Bool = false, limit: Int = 1000,
        accounts: CloudAccounts = .shared
    ) {
        self.text = text
        self.folder = folder
        self.everywhere = everywhere
        self.contents = contents
        self.limit = limit
        self.accounts = accounts
    }

    /// Where the results come from, for the status bar: "Google Drive", or "Google Drive · work" with two accounts.
    public var serviceTitle: String { accounts.account(for: folder).map { accounts.title($0.id) } ?? accounts.providerTitle(for: folder) }

    public func start() { page(nil) }

    public func stop() {
        stopped = true
        cancelPage?()
        cancelPage = nil
    }

    private func page(_ token: String?) {
        guard !stopped else { return }
        guard let backend = accounts.backend else { return finish(error: CloudEditError.notSupported) }
        var answered = false
        let cancel = backend.search(text, in: folder, everywhere: everywhere, contents: contents, pageToken: token) { [weak self] result in
            answered = true
            guard let self, !self.stopped else { return }
            self.cancelPage = nil
            switch result {
            case .failure(let error):
                self.finish(error: error)
            case .success(let page):
                // A page may repeat what an earlier one had (the service's results moved meanwhile): listed once.
                let new = page.items.filter { self.seen.insert($0.url).inserted }
                let room = max(0, self.limit - self.items.count)
                self.items += new.prefix(room)
                if new.count > room || (self.items.count >= self.limit && page.nextPageToken != nil) { self.isTruncated = true }
                // Drive may answer a page with nothing but the next token: keep going, but never round in circles.
                guard let next = page.nextPageToken, !self.isTruncated, self.tokens.insert(next).inserted else {
                    return self.finish(error: nil)
                }
                self.onResults?(self.items, false)
                self.page(next)
            }
        }
        if !answered { cancelPage = cancel }
    }

    private func finish(error: Error?) {
        self.error = error
        isDone = true
        onResults?(items, true)
    }

    /// What the status bar says once the search finished: "12 items found in Google Drive." and the like.
    public var summary: String {
        if let error {
            if (error as? CloudEditError) == .notSupported { return "Searching isn’t available in \(serviceTitle) yet." }
            if items.isEmpty { return "Couldn’t search \(serviceTitle): \(error.localizedDescription)" }
            return "\(FileFormat.itemCount(items.count)) found in \(serviceTitle); the rest couldn’t be loaded."
        }
        if isTruncated { return "Showing the first \(FileFormat.count(items.count)) items found in \(serviceTitle). Type more to narrow the search." }
        return items.isEmpty ? "No items found in \(serviceTitle)." : "\(FileFormat.itemCount(items.count)) found in \(serviceTitle)."
    }
}
