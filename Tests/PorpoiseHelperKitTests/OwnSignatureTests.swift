import Foundation
import PorpoiseHelperKit
import PorpoiseTestSupport
import Testing

@Suite struct OwnSignatureTests {
    @Test func requirementFollowsTheOwnCertificate() {
        let hash = CodeSigning.ownLeafCertificateHash()
        let requirement = CodeSigning.requirement(identifier: "app.porpoise.test")
        #expect((hash == nil) == (requirement == nil))
        if let hash {
            #expect(hash.count == 40 && hash.allSatisfy { $0.isHexDigit && !$0.isLowercase })
            #expect(requirement == #"identifier "app.porpoise.test" and certificate leaf = H""# + hash + "\"")
        }
        #expect(CodeSigning.ownLeafCertificateHash() == hash)  // stable
    }
}
