import Foundation

// Build once before timing: swiftc scripts/compare-debug.swift -o .build/compare-dbg
// The receiver exists only in a Porpoise launch with an isolated testing defaults suite.
let command = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !command.isEmpty else {
    FileHandle.standardError.write(Data("Usage: compare-dbg <DebugBridge command> [argument]\n".utf8))
    exit(64)
}
let channel = ProcessInfo.processInfo.environment["PORPOISE_BRIDGE"] ?? "test"
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("app.porpoise.Porpoise.debug." + channel), object: command, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.55))
