import Foundation

/// The environment variables that drive test instances: a throwaway settings suite, the debug bridge's channel, demo
/// and fake backends, artificial delays, and folders standing in for the system's.
///
/// Only builds with the PORPOISE_TEST_HOOKS flag read them: `swift test` (debug) and scripts/make-app.sh's local and
/// UI-test builds. A release (PORPOISE_RELEASE=1 scripts/make-app.sh) contains neither the names nor any way to set
/// them; the release workflow checks the final disk image for that.
public enum TestEnvironment: CaseIterable, Sendable {
    case defaultsSuite, bridge, testIndexDirectory, resources, templateDir, knownHosts, forceOnboarding, updateFeed
    case cloudDemo, offlineDemo, cloudBrowser, driveFake, dropboxFake, dropboxAppKey, oneDriveFake, oneDriveClientID, googleClientID,
        googleClientSecret
    case cleanupApps, cleanupLibrary, transferDelay, transferPreparationDelay, fileDiffReadDelayMs

    /// The variable's value in `environment` (the process's own by default); always nil in a release.
    public func value(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        #if PORPOISE_TEST_HOOKS
        environment[name]
        #else
        nil
        #endif
    }

    public var isSet: Bool { value() != nil }

    #if PORPOISE_TEST_HOOKS
    public var name: String {
        switch self {
        case .defaultsSuite: "PORPOISE_DEFAULTS_SUITE"
        case .bridge: "PORPOISE_BRIDGE"
        case .testIndexDirectory: "PORPOISE_TEST_INDEX_DIRECTORY"
        case .resources: "PORPOISE_RESOURCES"
        case .templateDir: "PORPOISE_TEMPLATE_DIR"
        case .knownHosts: "PORPOISE_KNOWN_HOSTS"
        case .forceOnboarding: "PORPOISE_FORCE_ONBOARDING"
        case .updateFeed: "PORPOISE_UPDATE_FEED"
        case .cloudDemo: "PORPOISE_CLOUD_DEMO"
        case .offlineDemo: "PORPOISE_OFFLINE_DEMO"
        case .cloudBrowser: "PORPOISE_CLOUD_BROWSER"
        case .driveFake: "PORPOISE_DRIVE_FAKE"
        case .dropboxFake: "PORPOISE_DROPBOX_FAKE"
        case .dropboxAppKey: "PORPOISE_DROPBOX_APP_KEY"
        case .oneDriveFake: "PORPOISE_ONEDRIVE_FAKE"
        case .oneDriveClientID: "PORPOISE_ONEDRIVE_CLIENT_ID"
        case .googleClientID: "PORPOISE_GOOGLE_CLIENT_ID"
        case .googleClientSecret: "PORPOISE_GOOGLE_CLIENT_SECRET"
        case .cleanupApps: "PORPOISE_CLEANUP_APPS"
        case .cleanupLibrary: "PORPOISE_CLEANUP_LIBRARY"
        case .transferDelay: "PORPOISE_TRANSFER_DELAY"
        case .transferPreparationDelay: "PORPOISE_TRANSFER_PREPARATION_DELAY"
        case .fileDiffReadDelayMs: "PORPOISE_FILEDIFF_READ_DELAY_MS"
        }
    }
    #endif
}
