import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

extension DirectoryModel {
    /// A model of `url`, set up by `setUp` and loaded (the test fails when it isn't within `timeout` seconds).
    @MainActor public static func loaded(_ url: URL, timeout: TimeInterval = 10, _ setUp: (DirectoryModel) -> Void = { _ in }) async throws
        -> DirectoryModel
    {
        let m = DirectoryModel(location: url)
        setUp(m)
        m.reload()
        try #require(await eventually(timeout) { !m.isLoading })
        return m
    }

    /// The names of the rows shown, in order.
    public var rowNames: [String] { rows.map(\.item.name) }
}

/// Holds the Spotlight queue until the returned function is called (a Spotlight that never answers), at most 30 s.
public func stallSpotlight() -> () -> Void {
    let release = DispatchSemaphore(value: 0)
    SpotlightQuery.queue.addOperation { _ = release.wait(timeout: .now() + 30) }
    return { release.signal() }
}
