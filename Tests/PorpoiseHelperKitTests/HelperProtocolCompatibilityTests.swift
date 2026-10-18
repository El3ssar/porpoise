import Foundation
import ObjectiveC
import PorpoiseHelperKit
import Testing

struct HelperProtocolCompatibilityTests {
    @Test func installedHelpersKeepTheSameProtocolAndSelectors() {
        let wireName = "PorpoiseCore.PorpoiseHelperProtocol"
        let proto = PorpoiseHelperProtocol.self
        #expect(String(cString: protocol_getName(proto)) == wireName)
        #expect(NSProtocolFromString(wireName).map { protocol_isEqual($0, proto) } == true)
        // Objective-C also accepts the original Swift-mangled lookup name.
        #expect(NSProtocolFromString("_TtP12PorpoiseCore22PorpoiseHelperProtocol_").map { protocol_isEqual($0, proto) } == true)
        let interface = NSXPCInterface(with: proto)
        #expect(protocol_isEqual(interface.protocol, proto))
        var count: UInt32 = 0
        let descriptions = protocol_copyMethodDescriptionList(proto, true, true, &count)
        defer { free(descriptions) }
        let selectors = (0..<Int(count)).compactMap { descriptions?[$0].name.map(NSStringFromSelector) }
        #expect(Set(selectors) == ["versionWithReply:", "run:reply:", "takeOwnershipOfTrashed:reply:", "checkFullDiskAccessWithReply:"])
    }
}
