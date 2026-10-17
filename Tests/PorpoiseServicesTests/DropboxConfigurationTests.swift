import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct DropboxConfigurationTests {
    @Test func keyPrecedenceEmptyValuesAndDescriptorAvailability() throws {
        let scratch = try Scratch()
        let directory = scratch.url.appendingPathComponent("Configuration.bundle")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.dropbox.configuration", "DropboxAppKey": " bundled-key "]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        let emptyDirectory = scratch.url.appendingPathComponent("Empty.bundle")
        try FileManager.default.createDirectory(at: emptyDirectory.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.dropbox.empty"], format: .xml, options: 0)
            .write(to: emptyDirectory.appendingPathComponent("Contents/Info.plist"))
        let emptyBundle = try #require(Bundle(url: emptyDirectory))
        #expect(!DropboxConfiguration.selected(defaults: MemoryDefaults(), environment: [:], bundle: emptyBundle).isConfigured)
        let defaults = MemoryDefaults()
        func selected(_ environment: [String: String] = [:]) -> DropboxConfiguration {
            .selected(defaults: defaults, environment: environment, bundle: bundle)
        }
        #expect(selected().appKey == "bundled-key")
        defaults.set(" settings-key ", forKey: "dropboxAppKey")
        #expect(selected().appKey == "settings-key")
        #expect(selected(["PORPOISE_DROPBOX_APP_KEY": " env-key "]).appKey == "env-key")
        #expect(selected(["PORPOISE_DROPBOX_APP_KEY": " \n "]).appKey == "settings-key")
        defaults.set(" \n ", forKey: "dropboxAppKey")
        #expect(selected(["PORPOISE_DROPBOX_APP_KEY": ""]).appKey == "bundled-key")
        for key in ["", " \n ", "configured-key"] {
            let configuration = DropboxConfiguration(appKey: key)
            let descriptor = try #require(CloudProviderDescriptor.catalog(dropbox: configuration).first { $0.provider == .dropbox })
            #expect(descriptor.available == (key == "configured-key"))
        }
        #expect(CloudProvider.googleDrive.isAvailable)
        let remote = DropboxLocation(accountID: UUID()).url
        #expect(PlacesModel.isCloud(remote) && CloudProviderDescriptor.descriptor(for: remote)?.provider == .dropbox)
        #expect(DropboxConfiguration(appKey: "key").loopbackPort == 53682)
    }

    @Test(.isolatedSettings) func changingTheSettingsKeyUpdatesAvailabilityWithoutRestart() {
        let hasExternalKey = DropboxConfiguration.selected(defaults: MemoryDefaults()).isConfigured
        if !hasExternalKey {
            #expect(!CloudProvider.dropbox.isAvailable)
            let accounts = CloudAccounts(); let backend = DemoCloudBackend(); accounts.backend = backend
            var refused = false
            _ = accounts.connect(.dropbox, openBrowser: { _ in Issue.record("Unexpected browser") }) {
                if case .failure = $0 { refused = true }
            }
            #expect(refused && !backend.isSigningIn)
        }
        Settings.store.set("fixture-settings-key", forKey: "dropboxAppKey")
        #expect(CloudProvider.dropbox.isAvailable)
        Settings.store.removeObject(forKey: "dropboxAppKey")
        #expect(CloudProvider.dropbox.isAvailable == hasExternalKey)
    }

    @Test func fixedLoopbackPortIsExactAndBusyPortFailsClosed() throws {
        var first: CloudOAuthLoopback? = try CloudOAuthLoopback()
        let port = UInt16(try #require(first?.redirectURL.port))
        #expect(throws: CloudOAuthError.self) { _ = try CloudOAuthLoopback(port: port) }
        first = nil
        let fixed = try CloudOAuthLoopback(port: port)
        #expect(fixed.redirectURL.absoluteString == "http://127.0.0.1:\(port)/oauth/callback")
    }
}
