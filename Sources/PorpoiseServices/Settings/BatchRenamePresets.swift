import Foundation
import PorpoiseCore

extension Settings {
    public var batchRenamePresets: [BatchRenamePreset] {
        get {
            // One by one: a preset this version can't read (a newer rule) is skipped, not all of them lost.
            guard let data = Settings.store.data(forKey: "batchRenamePresets"),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
            else { return [] }
            return raw.compactMap { entry in
                (try? JSONSerialization.data(withJSONObject: entry)).flatMap { try? JSONDecoder().decode(BatchRenamePreset.self, from: $0) }
            }
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            Settings.store.set(data, forKey: "batchRenamePresets")
            NotificationCenter.default.post(name: Settings.changed, object: "batchRenamePresets")
        }
    }
    public func saveBatchRenamePreset(_ preset: BatchRenamePreset) {
        var presets = batchRenamePresets.filter { $0.name != preset.name }
        presets.append(preset); batchRenamePresets = presets
    }
}
