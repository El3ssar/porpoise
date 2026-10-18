import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@Suite struct FileItemValueTests {
    @Test func typeDescriptionsWithoutAType() {
        func item(_ name: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: false) }
        #expect(item("README").typeDescription == "File")
        #expect(item("data.qqq").typeDescription == "QQQ file")
        #expect(item("README").mimeType == nil)
    }
}
