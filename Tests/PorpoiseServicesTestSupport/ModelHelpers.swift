import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

extension DirectoryModel {
    /// A model of `url`, set up by `setUp` and loaded (the test fails when it isn't within `timeout` seconds).
    @MainActor public static func loaded(
        _ url: URL, timeout: TimeInterval = eventualTimeout, _ setUp: (DirectoryModel) -> Void = { _ in }
    ) async throws -> DirectoryModel {
        let m = DirectoryModel(location: url)
        setUp(m)
        m.reload()
        try #require(await eventually(timeout) { !m.isLoading })
        return m
    }

    /// The names of the rows shown, in order.
    public var rowNames: [String] { rows.map(\.item.name) }
}

/// Holds the Spotlight queue until the returned function is called (a Spotlight that never answers), at most 300 s.
/// Use `.isolatedSpotlight` so the stall cannot time out an unrelated test's real query.
public func stallSpotlight() -> () -> Void {
    let release = DispatchSemaphore(value: 0)
    // The fallback only frees the queue if a test never resumes it; it must outlast any stall of a slow runner.
    SpotlightQuery.queue.addOperation { _ = release.wait(timeout: .now() + 300) }
    return { release.signal() }
}

extension PlacesModel {
    /// The titles of `section`'s entries, in order.
    public func titles(in section: PlaceSection) -> [String] { sections().first { $0.0 == section }?.1.map(\.title) ?? [] }
}

extension BatchRenameEntry {
    /// An entry for `name` in a folder that needn't exist.
    public static func named(_ name: String, directory: Bool = false) -> BatchRenameEntry {
        BatchRenameEntry(url: URL(fileURLWithPath: "/test/" + name), isDirectory: directory)
    }
}

extension DriveLocation {
    /// The folder's Drive ID, "root" for My Drive.
    public var folderIDOrRoot: String {
        if case .folder(let id, _) = collection { return id }
        return "root"
    }
}

extension SearchIndex {
    /// Waits until the index has built (the test fails, with its status, when it hasn't within `timeout` seconds).
    @MainActor public func waitUntilReady(timeout: TimeInterval = eventualTimeout) async throws {
        let ready = await eventually(timeout) { !self.status.building && self.status.updated != nil }
        try #require(ready, "Index startup: \(status)")
    }
}
