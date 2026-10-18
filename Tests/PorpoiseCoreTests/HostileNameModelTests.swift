import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@Suite struct HostileNameModelTests {
    private let names = HostileNames.all
    @Test func everyNameIsAValidSafeName() {
        #expect(Set(names.map(bytes)).count == names.count)
        for n in names {
            #expect(FileActions.isValidName(n), "\(n.debugDescription)")
            #expect(RemoteParsing.isSafeName(n), "\(n.debugDescription)")
        }
        for n in [HostileNames.long255Ascii, HostileNames.long255TwoByte, HostileNames.long255Emoji] { #expect(n.utf8.count == 255) }
    }
    @Test func duplicateAndSuggestedNamesStayValidAndNew() {
        for n in names {
            var existing: Set<String> = [n]
            for _ in 0..<3 {
                let d = FileFormat.duplicateName(for: n, existing: existing)
                let s = FileFormat.suggestedName(for: n, existing: existing)
                #expect(!existing.contains(d) && !existing.contains(s))
                #expect(!d.contains("/") && !s.contains("/") && d != "." && s != "..")
                existing.insert(d); existing.insert(s)
            }
        }
    }
}
