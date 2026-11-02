import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let regression = CommandLine.arguments.contains("--regression")
var checkpoints = 0, atFirstFile: Int?
let cancellation = DiskCancellation(checkpoint: { checkpoints += 1 })
let started = ProcessInfo.processInfo.systemUptime
var first: Double?
let total = TreeMeasure.measure([root], cancellation: cancellation, reportInterval: regression ? 0 : 0.25) { progress in
    if progress.files > 0 && first == nil {
        first = ProcessInfo.processInfo.systemUptime - started
        atFirstFile = checkpoints
        if regression { cancellation.cancel() }
    }
}
let elapsed = ProcessInfo.processInfo.systemUptime - started
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
var report: [String: Any] = [
    "firstUsefulSeconds": first ?? elapsed, "totalSeconds": elapsed,
    "peakRSSBytes": usage.ru_maxrss, "checkpointsAtFirstFile": atFirstFile ?? -1,
]
if regression {
    let passed = total == nil && atFirstFile != nil && atFirstFile! <= 5
    report["passed"] = passed
    print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    exit(passed ? 0 : 1)
}
report["files"] = total?.files ?? -1
report["folders"] = total?.folders ?? -1
report["bytes"] = total?.bytes ?? -1
report["errors"] = total?.errors.count ?? -1
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
