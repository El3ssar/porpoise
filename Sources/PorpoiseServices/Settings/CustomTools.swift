import Foundation
import PorpoiseCore

extension Settings {
    /// No automatic discovery, imports or execution from browsed folders.
    public var customTools: [CustomTool] { loadCustomTools(from: Settings.store) }

    /// Only automatic menu/toolbar construction may omit tools until the first window. Editors, explicit actions,
    /// runners and shortcut validation must use `customTools`, which always returns the saved document.
    public var customToolsIfLoaded: [CustomTool] {
        let store = Settings.store
        customToolsLock.lock()
        let loaded = customToolsCache?.store === store
        customToolsLock.unlock()
        guard loaded else { return [] }
        return loadCustomTools(from: store)
    }

    private func loadCustomTools(from store: UserDefaults) -> [CustomTool] {
        customToolsLock.lock(); defer { customToolsLock.unlock() }
        let data = store.data(forKey: "customTools")
        if let cache = customToolsCache, cache.store === store, cache.data == data { return cache.tools }
        let tools = data.flatMap { try? CustomToolDocument.decode($0).tools } ?? []
        // A request from an earlier settings scope may finish after a replacement has already warmed its cache.
        if Settings.store === store { customToolsCache = (store, data, tools) }
        return tools
    }

    /// Warm the document on a worker after drawing the first window; menu/toolbar rebuilding then uses the cache.
    public func prepareCustomToolsAfterFirstWindow(completion: @escaping () -> Void = {}) {
        prepareCustomToolsAfterFirstWindow(on: .global(qos: .utility), completion: completion)
    }

    func prepareCustomToolsAfterFirstWindow(on queue: DispatchQueue, completion: @escaping () -> Void = {}) {
        let store = Settings.store
        queue.async {
            let hasTools = !self.loadCustomTools(from: store).isEmpty
            DispatchQueue.main.async {
                completion()
                if hasTools, Settings.store === store { NotificationCenter.default.post(name: Settings.changed, object: "customTools") }
            }
        }
    }
    public func saveCustomTools(_ tools: [CustomTool]) throws {
        let data = try CustomToolDocument(tools: tools).encoded()
        let store = Settings.store
        customToolsLock.lock()
        store.set(data, forKey: "customTools")
        customToolsCache = (store, data, tools)
        customToolsLock.unlock()
        NotificationCenter.default.post(name: Settings.changed, object: "customTools")
    }
    public func importCustomTools(_ data: Data) throws { try saveCustomTools(CustomToolDocument.decode(data).tools) }
}
