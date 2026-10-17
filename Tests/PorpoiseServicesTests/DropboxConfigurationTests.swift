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
        #expect(DropboxConfiguration(appKey: "key").loopbackPorts == [61843, 61844, 61845])
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
        #expect(throws: CloudOAuthLoopback.PortInUse.self) { _ = try CloudOAuthLoopback(port: port) }
        first = nil
        let fixed = try CloudOAuthLoopback(port: port)
        #expect(fixed.redirectURL.absoluteString == "http://127.0.0.1:\(port)/oauth/callback")
    }
    @Test func busyDropboxPortsFallBackInOrderAndExplainExhaustion() throws {
        // Reserve a free adjacent range. Keep every socket open for the assertions; no timing sleeps.
        var blockers: [CloudOAuthLoopback] = []
        var base: UInt16 = 0
        for _ in 0..<100 {
            let first = try CloudOAuthLoopback()
            let candidate = UInt16(try #require(first.redirectURL.port))
            guard candidate <= UInt16.max - 2 else { continue }
            do {
                let second = try CloudOAuthLoopback(port: candidate + 1)
                let third = try CloudOAuthLoopback(port: candidate + 2)
                blockers = [first, second, third]; base = candidate; break
            } catch is CloudOAuthLoopback.PortInUse { continue }
        }
        try #require(blockers.count == 3)
        let configuration = DropboxConfiguration(appKey: "fixture", loopbackPort: base)
        // Release P+1 and P+2, leaving P busy.
        blockers.removeLast(); blockers.removeLast()
        func assertFallback(_ port: UInt16) throws {
            let fallback = try configuration.makeLoopbackListener()
            #expect(fallback.redirectURL.port == Int(port))
        }
        try assertFallback(base + 1)
        blockers.append(try CloudOAuthLoopback(port: base + 1))
        try assertFallback(base + 2)
        blockers.append(try CloudOAuthLoopback(port: base + 2))
        #expect(throws: DropboxCallbackError.portsBusy([base, base + 1, base + 2])) {
            _ = try configuration.makeLoopbackListener()
        }
        let error = DropboxCallbackError.portsBusy(configuration.loopbackPorts).localizedDescription
        #expect(error.contains("in use") && error.contains("try again"))
        #expect(configuration.loopbackPorts.allSatisfy { error.contains(String($0)) })
        blockers.removeFirst(); try assertFallback(base)
        withExtendedLifetime(blockers) {}
        let ephemeral = try DropboxConfiguration(appKey: "fixture", loopbackPort: 0).makeLoopbackListener()
        #expect(ephemeral.redirectURL.port != 0)
    }

}
