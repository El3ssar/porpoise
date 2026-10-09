// Sends a command to the running app's DebugBridge: dbg snapshot <png> | state <json> | navigate <dir> | action <selector:>
import Foundation
let args = CommandLine.arguments.dropFirst().joined(separator: " ")
// PORPOISE_BRIDGE selects a test instance started with the same variable.
let channel = "app.porpoise.Porpoise.debug." + (ProcessInfo.processInfo.environment["PORPOISE_BRIDGE"] ?? "test")
DistributedNotificationCenter.default().postNotificationName(Notification.Name(channel), object: args, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.6))
