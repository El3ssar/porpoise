import Foundation

/// The app's diagnostic events: one store for the process, recorded at the main error sites and exported only from
/// Help › Export Diagnostics… after the user has seen exactly what it holds. Nothing is written to disk or sent.
public enum Diagnostics {
    public static let shared = DiagnosticStore()

    /// Set while the app runs, cleared when it quits: still set at launch means the last run ended without quitting.
    static let runningKey = "diagnostics.running"

    /// At launch: records an unclean exit of the previous run, then marks this one as running.
    public static func launched(store: DiagnosticStore = shared) {
        if Settings.store.bool(forKey: runningKey) { store.record(.appUncleanExit, failure: .unknown) }
        Settings.store.set(true, forKey: runningKey)
    }

    /// When the app quits normally.
    public static func quitting() {
        Settings.store.set(false, forKey: runningKey)
    }
}
