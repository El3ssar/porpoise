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

extension AutomationCLITests {
    func testReadCommandsAndPagination() throws {
        let parsed = try AutomationCLI.parse(["list", "--limit", "50", "--offset", "100", "--json"], directory: "/work")
        XCTAssertEqual(parsed.request.action, .list)
        XCTAssertEqual(parsed.request.limit, 50)
        XCTAssertEqual(parsed.request.offset, 100)
        XCTAssertEqual(try AutomationCLI.parse(["pwd"], directory: "/").request.action, .location)
        XCTAssertEqual(try AutomationCLI.parse(["ls"], directory: "/").request.action, .list)
        XCTAssertEqual(try AutomationCLI.parse(["status", "--json"], directory: "/").request.action, .status)
        for args in [
            ["list", "--limit", "0"], ["list", "--limit", "10001"], ["list", "--offset", "-1"], ["status", "path"], ["open", "x", "--limit", "10"],
        ] {
            XCTAssertThrowsError(try AutomationCLI.parse(args, directory: "/"), "\(args)")
        }
    }

    func testTransferPlansAndTimeoutsDoNotAlterRequestSemantics() throws {
        let parsed = try AutomationCLI.parse(
            ["copy", "file", "--to", "out", "--dry-run", "--json", "--launch", "--timeout", "2.5"], directory: "/work")
        XCTAssertTrue(parsed.dryRun)
        XCTAssertTrue(parsed.launch)
        XCTAssertEqual(parsed.timeout, 2.5)
        XCTAssertEqual(parsed.request.paths, ["/work/file"])
        XCTAssertEqual(parsed.request.destination, "/work/out")
        for args in [
            ["open", "x", "--dry-run"], ["status", "--timeout", "nan"], ["status", "--timeout", "0"], ["status", "--timeout", "121"],
            ["status", "--timeout", "5", "--timeout", "6"],
        ] {
            XCTAssertThrowsError(try AutomationCLI.parse(args, directory: "/"), "\(args)")
        }
    }

    func testHelpAndCompletionsCoverEveryPublicCommand() {
        for command in AutomationCLI.commands {
            let help = AutomationCLI.help(for: command)
            XCTAssertNotNil(help)
            XCTAssertTrue(help?.contains("Usage:") == true)
            XCTAssertTrue(help?.contains("Example:") == true)
        }
        for shell in ["bash", "zsh", "fish"] { XCTAssertNotNil(AutomationCLI.completions(for: shell)) }
        XCTAssertNil(AutomationCLI.completions(for: "unknown"))
    }

    func testLegacyRequestsDecodeWithoutNewOptionalFields() throws {
        let id = UUID()
        let legacy = Data("{\"version\":1,\"id\":\"\(id.uuidString)\",\"action\":\"selection\",\"paths\":[],\"useSelection\":false}".utf8)
        let request = try JSONDecoder().decode(AutomationRequest.self, from: legacy)
        XCTAssertEqual(request.id, id)
        XCTAssertNil(request.limit)
        XCTAssertNil(request.offset)
        try request.validate()
    }

    func testUsageErrorsNameTheInvalidOptionAndNextStep() {
        XCTAssertThrowsError(try AutomationCLI.parse(["open", "folder", "--typo"], directory: "/")) { error in
            XCTAssertTrue(error.localizedDescription.contains("--typo"))
            XCTAssertTrue(error.localizedDescription.contains("porpoise help open"))
        }
    }
}
