import Foundation
import PorpoiseCore

extension Settings {
    /// No automatic discovery, imports or execution from browsed folders.
    public var customTools: [CustomTool] {
        guard let data = Settings.store.data(forKey: "customTools") else { return [] }
        return (try? CustomToolDocument.decode(data).tools) ?? []
    }
    public func saveCustomTools(_ tools: [CustomTool]) throws {
        let data = try CustomToolDocument(tools: tools).encoded()
        Settings.store.set(data, forKey: "customTools")
        NotificationCenter.default.post(name: Settings.changed, object: "customTools")
    }
    public func importCustomTools(_ data: Data) throws { try saveCustomTools(CustomToolDocument.decode(data).tools) }
}
