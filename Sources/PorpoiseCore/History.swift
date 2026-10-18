import Foundation

/// Back/forward history of one view (each pane of each tab has its own, like Dolphin).
public struct NavigationHistory: Sendable {
    /// Oldest entries are dropped beyond this.
    public static let maxEntries = 100

    public private(set) var entries: [URL]
    public private(set) var index: Int

    public init(start: URL) {
        entries = [start]
        index = 0
    }

    public var current: URL { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }
    /// Most recent first, for the Back dropdown.
    public var backList: [URL] { Array(entries[..<index].reversed()) }
    public var forwardList: [URL] { Array(entries[(index + 1)...]) }

    public mutating func visit(_ url: URL) {
        if url == current { return }
        entries.removeSubrange((index + 1)...)
        entries.append(url)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        index = entries.count - 1
    }

    @discardableResult public mutating func goBack(_ steps: Int = 1) -> URL? {
        guard steps > 0, index - steps >= 0 else { return nil }
        index -= steps
        return current
    }

    @discardableResult public mutating func goForward(_ steps: Int = 1) -> URL? {
        guard steps > 0, index + steps < entries.count else { return nil }
        index += steps
        return current
    }
}
