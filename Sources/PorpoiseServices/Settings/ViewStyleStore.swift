import CoreGraphics
import Foundation
import PorpoiseCore

/// Where a location's display style is kept, and what it is until one is saved there.
public struct LocationKey: Equatable {
    /// The key in the saved styles: the path on this Mac, else the location without a password typed into it.
    public let stored: String
    /// The location's own built-in style (Downloads by date, a result list as Details…); the common one if it has none.
    public let builtIn: ViewProperties?

    public init(_ url: URL) {
        stored = url.isFileURL ? url.path : RemoteFS.withoutPassword(url).absoluteString
        let style = LocationContentSources.defaultStyle(for: url)
        builtIn = style == ViewProperties() ? nil : style
    }
}

/// The display styles people chose: the common one, each folder's own ("Remember display style for each folder"),
/// and the Details column widths. The stored keys and formats are those of every earlier version.
public struct ViewStyleStore {
    private var d: UserDefaults { Settings.store }
    public init() {}

    /// The style used everywhere unless each folder remembers its own.
    var common: ViewProperties {
        get {
            guard let data = d.data(forKey: "viewProps"), let p = try? JSONDecoder().decode(ViewProperties.self, from: data) else {
                return ViewProperties()
            }
            return p
        }
        nonmutating set {
            d.set(try? JSONEncoder().encode(newValue), forKey: "viewProps")
        }
    }

    /// The display style for a location. "Use common display style for all folders": one style everywhere, and a
    /// change made in any folder changes it. "Remember display style for each folder": the folder's own saved style,
    /// else its built-in style, else the common style.
    public func style(for key: LocationKey, restoringDefaults: Bool = false) -> ViewProperties {
        let common = restoringDefaults ? ViewProperties() : common
        guard Settings.shared.rememberPerFolder else { return common }
        if !restoringDefaults, let data = d.dictionary(forKey: "folderProps")?[key.stored] as? Data,
            let p = try? JSONDecoder().decode(ViewProperties.self, from: data)
        {
            return p
        }
        return key.builtIn ?? common
    }

    public func style(for url: URL, restoringDefaults: Bool = false) -> ViewProperties {
        style(for: LocationKey(url), restoringDefaults: restoringDefaults)
    }

    public func save(_ style: ViewProperties, for key: LocationKey) {
        if Settings.shared.rememberPerFolder {
            var dict = d.dictionary(forKey: "folderProps") ?? [:]
            dict[key.stored] = try? JSONEncoder().encode(style)
            d.set(dict, forKey: "folderProps")
        } else {
            common = style
        }
    }

    public func save(_ style: ViewProperties, for url: URL) { save(style, for: LocationKey(url)) }

    /// Details column widths by role, the same in every folder; none saved: the columns fit the window.
    public var columnWidths: [String: CGFloat] {
        get { (d.dictionary(forKey: "columnWidths") as? [String: Double])?.mapValues { CGFloat($0) } ?? [:] }
        nonmutating set { d.set(newValue.mapValues { Double($0) }, forKey: "columnWidths") }
    }
}
