import Foundation
import PorpoiseServicesTestSupport
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
            .selected(defaults: defaults, environment: environment, bundle: bundle, testing: true)  // a test instance reads the environment
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

    /// A listener on a fixed port takes exactly that port, and a second one on it fails rather than taking another. The
    /// port stays held throughout: one released here would close asynchronously, and binding it again at once could
    /// fail (#2649).
    @Test func fixedLoopbackPortIsExactAndBusyPortFailsClosed() throws {
        var fixed: CloudOAuthLoopback?
        var port: UInt16 = 0
        for _ in 0..<100 {
            port = UInt16.random(in: 20000...40000)
            do {
                fixed = try CloudOAuthLoopback(port: port); break
            } catch is CloudOAuthLoopback.PortInUse { continue }
        }
        let listener = try #require(fixed)
        #expect(listener.redirectURL.absoluteString == "http://127.0.0.1:\(port)/oauth/callback")
        #expect(throws: CloudOAuthLoopback.PortInUse.self) { _ = try CloudOAuthLoopback(port: port) }
        withExtendedLifetime(listener) {}
    }
    /// The registered port first, then the next two in order; all three busy: a message that names them. Checked
    /// against a scripted set of busy ports: real sockets close asynchronously, so a port a test just released can
    /// still look busy (the flake in #2649), and one another process takes can't be predicted.
    @Test func busyDropboxPortsFallBackInOrderAndExplainExhaustion() throws {
        let configuration = DropboxConfiguration(appKey: "fixture", loopbackPort: 30000)
        #expect(configuration.loopbackPorts == [30000, 30001, 30002])
        func first(busy: Set<UInt16>) throws -> UInt16 {
            var tried: [UInt16] = []
            let port: UInt16 = try configuration.makeLoopbackListener { port in
                tried.append(port)
                if busy.contains(port) { throw CloudOAuthLoopback.PortInUse(port: port) }
                return port
            }
            #expect(tried == Array(configuration.loopbackPorts.prefix(tried.count)))
            return port
        }
        #expect(try first(busy: []) == 30000)
        #expect(try first(busy: [30000]) == 30001)
        #expect(try first(busy: [30000, 30001]) == 30002)
        #expect(try first(busy: [30001]) == 30000)
        #expect(throws: DropboxCallbackError.portsBusy([30000, 30001, 30002])) { _ = try first(busy: [30000, 30001, 30002]) }
        let error = DropboxCallbackError.portsBusy(configuration.loopbackPorts).localizedDescription
        #expect(error.contains("in use") && error.contains("try again"))
        #expect(configuration.loopbackPorts.allSatisfy { error.contains(String($0)) })
    }

    /// On real sockets: a port held by another listener is skipped. The held one is never released during the test.
    @Test func aRealBusyPortIsSkipped() throws {
        // Below the ephemeral range, where parallel HTTP tests take their ports, so the next two are likely free.
        var bound: CloudOAuthLoopback?
        var port: UInt16 = 0
        for _ in 0..<100 {
            port = UInt16.random(in: 20000...40000)
            do {
                bound = try CloudOAuthLoopback(port: port); break
            } catch is CloudOAuthLoopback.PortInUse { continue }
        }
        let held = try #require(bound)
        let listener = try DropboxConfiguration(appKey: "fixture", loopbackPort: port).makeLoopbackListener()
        #expect(listener.redirectURL.port != Int(port))
        withExtendedLifetime(held) {}
        let ephemeral = try DropboxConfiguration(appKey: "fixture", loopbackPort: 0).makeLoopbackListener()
        #expect(ephemeral.redirectURL.port != 0)
    }

}
