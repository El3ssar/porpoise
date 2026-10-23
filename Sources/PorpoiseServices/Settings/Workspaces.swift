import Foundation
import PorpoiseCore

extension Settings {
    /// Named workspaces, sorted by name.
    public var workspaces: [Workspace] {
        get {
            // One by one: a workspace this version can't read (a newer format) is skipped, not all of them lost.
            guard let data = Settings.store.data(forKey: "workspaces"),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
            else { return [] }
            return Workspace.sorted(
                raw.compactMap { entry in
                    (try? JSONSerialization.data(withJSONObject: entry)).flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }
                })
        }
        set {
            guard let data = try? JSONEncoder().encode(Workspace.sorted(newValue)) else { return }
            Settings.store.set(data, forKey: "workspaces")
            NotificationCenter.default.post(name: Settings.changed, object: "workspaces")
        }
    }

    /// Saves `layout` as `name`, replacing a workspace of that name (any case); returns what was saved, nil for an
    /// empty name.
    @discardableResult
    public func saveWorkspace(named name: String, layout: WindowLayout) -> Workspace? {
        guard let clean = Workspace.cleanName(name) else { return nil }
        var all = workspaces
        let existing = Workspace.named(clean, in: all)
        let saved = Workspace(id: existing?.id ?? UUID(), name: clean, layout: layout)
        all.removeAll { $0.id == saved.id }
        all.append(saved)
        workspaces = all
        return saved
    }

    public func deleteWorkspace(id: UUID) { workspaces = workspaces.filter { $0.id != id } }

    /// Gives a workspace a new name; false when the name is empty or another workspace has it.
    @discardableResult
    public func renameWorkspace(id: UUID, to name: String) -> Bool {
        guard let clean = Workspace.cleanName(name) else { return false }
        var all = workspaces
        guard let i = all.firstIndex(where: { $0.id == id }) else { return false }
        if let other = Workspace.named(clean, in: all), other.id != id { return false }
        all[i].name = clean
        workspaces = all
        return true
    }
}
