import Darwin
import Foundation
import PorpoiseCore
import PorpoiseServices

// swift run -c release PlanJournalBenchmark <new-root> [file-count=20000] [limit=0] [journal|direct]
let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("Provide a new scratch root; optional file count, step limit and journal/direct mode.") }
let root = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
let count = args.count > 2 ? Int(args[2]) ?? 20_000 : 20_000
let limit = args.count > 3 ? Int(args[3]) ?? 0 : 0
let mode = args.count > 4 ? args[4] : "journal"
let fm = FileManager.default
guard !fm.fileExists(atPath: root.path) else { fatalError("Benchmark root must be new; existing data is never removed.") }
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let left = root.appendingPathComponent("A"), right = root.appendingPathComponent("B")
try fm.createDirectory(at: left, withIntermediateDirectories: true)
try fm.createDirectory(at: right, withIntermediateDirectories: true)
let bytes = Data(repeating: 0x61, count: 1024)
for index in 0..<count { try bytes.write(to: left.appendingPathComponent(String(format: "file-%06d.txt", index))) }
let comparison = try SyncScanner.compare(left, right).comparison
let plan = SyncPlanner.plan(comparison, mode: .mirror)
let journal = try SyncJobs.journal(plan, title: "20k-file Mirror benchmark", leftRoot: left, rightRoot: right)
let baselineBytes = try JSONEncoder().encode(journal).count
let store = PlanJournalStore(folder: root.appendingPathComponent("Plans"))
func usage() -> rusage_info_v4 {
    var result = rusage_info_v4()
    withUnsafeMutablePointer(to: &result) { pointer in
        _ = pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return result
}
func journalSize() -> Int64 {
    ((try? fm.contentsOfDirectory(at: store.folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []).reduce(0) {
        $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
let before = usage(), started = ProcessInfo.processInfo.systemUptime
var copied = 0, retainedJournalBytes: Int64 = 0
if mode == "direct" {
    for step in plan.steps {
        try SyncExecutor.execute(step, leftRoot: left, rightRoot: right)
        copied += 1
        if limit > 0 && copied >= limit { break }
    }
} else {
    let job = PlanJob(journal: journal, store: store)
    job.onProgress = { progress in if progress.completedSteps == plan.steps.count { retainedJournalBytes = journalSize() } }
    do {
        try job.run { step, context in
            try SyncJobs.execute(step, context: context); copied += 1
            if limit > 0 && copied >= limit { job.interrupt() }
        }
    } catch FileOperationError.interrupted { retainedJournalBytes = journalSize() }
}
let elapsed = ProcessInfo.processInfo.systemUptime - started, after = usage()
let result: [String: Any] = [
    "pid": getpid(), "root": root.path, "mode": mode, "plannedSteps": plan.steps.count, "copied": copied,
    "seconds": elapsed, "filesPerSecond": Double(copied) / elapsed, "payloadBytesPerFile": bytes.count,
    "baselineJSONBytes": baselineBytes, "retainedJournalBytes": retainedJournalBytes,
    "processLogicalWrites": after.ri_logical_writes - before.ri_logical_writes,
    "processDiskBytesWritten": after.ri_diskio_byteswritten - before.ri_diskio_byteswritten,
    "destinationFileCount": try fm.contentsOfDirectory(atPath: right.path).count,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
