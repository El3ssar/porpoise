import Foundation

extension CloudBackend {
    public func content(for accountID: String) -> CloudContentSource? { nil }
    public func content(for url: URL) -> CloudContentSource? {
        accountID(for: url).flatMap { content(for: $0) }
    }
}
