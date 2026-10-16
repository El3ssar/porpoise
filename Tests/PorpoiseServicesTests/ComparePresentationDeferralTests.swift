import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings, .serialized)
struct ComparePresentationDeferralTests {
    @Test func hiddenBrowseSortingDefersAndResumesWithLatestProperties() async throws {
        let scratch = try Scratch()
        try scratch.file("a"); try scratch.file("b")
        let model = DirectoryModel(location: scratch.url)
        model.reload()
        #expect(await eventually(5) { !model.isLoading && model.rows.count == 2 })
        var props = model.props; props.sortRole = .name; props.sortOrder = .ascending; model.props = props
        let before = model.rows.map(\.item.name)
        var changes = 0; model.onChange = { changes += 1 }
        model.defersPresentation = true
        props.sortOrder = .descending; model.props = props
        #expect(model.rows.map(\.item.name) == before)
        #expect(changes == 0)
        model.defersPresentation = false
        #expect(model.rows.map(\.item.name) == before.reversed())
        #expect(changes == 1)
    }
}
