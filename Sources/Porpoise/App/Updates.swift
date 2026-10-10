import AppKit
import PorpoiseServices
import Sparkle

/// In-app updates with Sparkle: a daily check (optional, in Settings › General), Sparkle's update window with the
/// release notes, then download, signature check, install and relaunch. The feed is published by the release
/// workflow next to each release (see SUFeedURL in Info.plist); updates are signed with the project's EdDSA key.
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    /// Test instances don't update themselves unless given a feed to test against (PORPOISE_UPDATE_FEED).
    private var feedOverride: String? { ProcessInfo.processInfo.environment["PORPOISE_UPDATE_FEED"] }

    func start() {
        guard controller == nil, !Settings.isTesting || feedOverride != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    @objc func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }

    /// Check once a day, in the background.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Download and install found updates without asking (applied when Porpoise quits).
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { feedOverride }
}
