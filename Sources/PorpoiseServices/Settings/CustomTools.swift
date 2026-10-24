import Foundation
import PorpoiseCore

extension Settings {
    /// No automatic discovery, imports or execution from browsed folders.
    public var customTools: [CustomTool] {
        let store = Settings.store, data = store.data(forKey: "customTools")
        customToolsLock.lock(); defer { customToolsLock.unlock() }
        if let cache = customToolsCache, cache.store == ObjectIdentifier(store), cache.data == data { return cache.tools }
        let tools = data.flatMap { try? CustomToolDocument.decode($0).tools } ?? []
        customToolsCache = (ObjectIdentifier(store), data, tools)
        return tools
    }
    public func saveCustomTools(_ tools: [CustomTool]) throws {
        let data = try CustomToolDocument(tools: tools).encoded()
        let store = Settings.store
        customToolsLock.lock()
        store.set(data, forKey: "customTools")
        customToolsCache = (ObjectIdentifier(store), data, tools)
        customToolsLock.unlock()
        NotificationCenter.default.post(name: Settings.changed, object: "customTools")
    }
    public func importCustomTools(_ data: Data) throws { try saveCustomTools(CustomToolDocument.decode(data).tools) }
}
