import Testing
@testable import PorpoiseCore

@Suite struct VersionTests {
    @Test func comparesNumerically() {
        #expect(Version.isNewer("0.10.0", than: "0.9.2"))
        #expect(Version.isNewer("v1.0.1", than: "1.0"))
        #expect(!Version.isNewer("1.0", than: "1.0.0"))
        #expect(!Version.isNewer("0.9", than: "0.10"))
    }
}
