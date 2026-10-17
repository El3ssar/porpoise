import Foundation
import Testing

@testable import PorpoiseServices

/// The test switches as test builds see them (a release has none: scripts/check-release.sh).
struct TestEnvironmentTests {
    @Test func everySwitchHasItsOwnPorpoiseName() {
        let names = TestEnvironment.allCases.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("PORPOISE_") && $0 == $0.uppercased() })
    }

    @Test func valuesComeFromTheGivenEnvironment() {
        let env = ["PORPOISE_DEFAULTS_SUITE": "app.porpoise.t", "PORPOISE_BRIDGE": "t"]
        #expect(TestEnvironment.defaultsSuite.value(in: env) == "app.porpoise.t")
        #expect(TestEnvironment.bridge.value(in: env) == "t")
        #expect(TestEnvironment.cloudDemo.value(in: env) == nil)
    }
}
