import Foundation
import Testing
@testable import PorpoiseServices

/// Settings live in UserDefaults; tests use a throwaway domain and remove it.
@Suite(.serialized) struct SettingsTests {
    @Test func valuesRoundTripThroughTheStore() throws {
        let domain = "app.porpoise.tests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        store.set(true, forKey: "fullPathTitle")
        #expect(store.bool(forKey: "fullPathTitle"))
    }
}
