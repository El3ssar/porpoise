import XCTest

@testable import PorpoiseCore

final class AutomationCLITests: XCTestCase {
    func testPathsAreLiteralAndRelativeToCaller() throws {
        let names = ["space name", "quote'\"", "line\nbreak", "日本語", "$(touch INJECTED)"]
        let parsed = try AutomationCLI.parse(["copy"] + names + ["--to", "../target"], directory: "/work/source")
        XCTAssertEqual(parsed.request.paths, names.map { "/work/source/" + $0 })
        XCTAssertEqual(parsed.request.destination, "/work/source/../target")
        XCTAssertEqual(parsed.request.action, .copy)
    }

    func testSymlinkSensitiveComponentsReachTheFilesystemUnchanged() throws {
        let parsed = try AutomationCLI.parse(["move", "link/../item", "--to", "/out/link/../folder"], directory: "/work")
        XCTAssertEqual(parsed.request.paths, ["/work/link/../item"])
        XCTAssertEqual(parsed.request.destination, "/out/link/../folder")
        XCTAssertEqual(try AutomationCLI.parse(["reveal", "./item"], directory: "/").request.paths, ["/./item"])
    }

    func testSelectionAndLiteralOptions() throws {
        XCTAssertTrue(try AutomationCLI.parse(["move", "--selection", "--to", "/out"], directory: "/").request.useSelection)
        XCTAssertEqual(try AutomationCLI.parse(["reveal", "--", "-name"], directory: "/tmp").request.paths, ["/tmp/-name"])
        let json = try AutomationCLI.parse(["selection", "--json"], directory: "/")
        if case .json = json.output {} else { XCTFail("Expected JSON") }
    }

    func testRejectsMalformedCommands() {
        for args in [
            [], ["runTool"], ["open"], ["split", "a"], ["open", "a", "b"], ["selection", "x"],
            ["selection", "--json", "--null"], ["copy", "a"], ["move", "--selection", "a", "--to", "b"],
            ["copy", "a", "--to"], ["open", "--unknown"], ["open", "a\0b"],
        ] {
            XCTAssertThrowsError(try AutomationCLI.parse(args, directory: "/"), "\(args)")
        }
    }

    func testWireRoundTripAndVersionBoundary() throws {
        var request = AutomationRequest(action: .runTool, toolID: UUID(), promptValue: "quote'\n")
        XCTAssertEqual(try JSONDecoder().decode(AutomationRequest.self, from: JSONEncoder().encode(request)), request)
        request.version = 2
        XCTAssertThrowsError(try request.validate())
    }
}
