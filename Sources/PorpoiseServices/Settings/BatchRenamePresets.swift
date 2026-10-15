import Foundation
import PorpoiseCore

extension Settings {
    public var batchRenamePresets: [BatchRenamePreset] {
        get {
            guard let data = Settings.store.data(forKey: "batchRenamePresets"),
                let presets = try? JSONDecoder().decode([BatchRenamePreset].self, from: data)
            else { return [] }
            return presets
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
