import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Runs a command line tool and fails the test if it fails.
@discardableResult
func run(_ tool: String, _ args: [String], in dir: URL? = nil) throws -> String {
    // runTool drains stderr too: an unread stderr pipe blocks a tool that writes more than the pipe holds.
    let r = try runTool(tool, args, cwd: dir)
    guard r.status == 0 else {
        let why = String(decoding: r.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(args.joined(separator: " ")) failed: \(why)"])
    }
    return String(decoding: r.out, as: UTF8.self)
}
