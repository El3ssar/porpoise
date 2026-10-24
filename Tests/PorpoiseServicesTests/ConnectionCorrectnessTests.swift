import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite struct MountIdentityTests {
    @Test func explicitUsersAndEffectivePortsMustMatch() {
        let volume = URL(fileURLWithPath: "/Volumes/share")
        func matches(_ request: String, _ mounted: String) -> Bool {
            NetworkMounts.path(of: URL(string: request)!, onVolume: volume, mountedFrom: URL(string: mounted)!) != nil
        }
        #expect(!matches("smb://alice@nas/share", "smb://bob@nas/share"))
        #expect(!matches("smb://alice@nas/share", "smb://nas/share"))
        #expect(matches("smb://alice@nas/share", "smb://alice@NAS:445/share"))
        #expect(matches("smb://nas/share", "smb://bob@nas/share"))
        #expect(!matches("https://nas:9443/share", "https://nas:8443/share"))
        #expect(matches("https://nas/share/sub", "https://nas:443/share"))
        #expect(!matches("https://nas/share", "https://nas:80/share"))
    }
}
