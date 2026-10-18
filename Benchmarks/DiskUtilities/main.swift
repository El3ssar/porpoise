import Foundation

func now() -> Double { ProcessInfo.processInfo.systemUptime }
func arg(_ n: Int, _ fallback: String) -> String { CommandLine.arguments.count > n ? CommandLine.arguments[n] : fallback }
func residentMB() -> Double {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1e6 : 0
}
// UsageTree sort by recomputed url.path, n entries.
let n = Int(arg(2, "1000000"))!
var scan = DiskScan()
scan.entries.reserveCapacity(n)
let base = "/Users/someone/Library/Containers/com.example.app/Data/Library/Caches"
var dirs = 0
for i in 0..<n {
    if i % 1000 == 0 {
        dirs += 1;
        scan.entries.append(
            DiskEntry(
                url: URL(fileURLWithPath: "\(base)/d\(dirs)", isDirectory: true), identity: .init(device: 1, inode: UInt64(i)), directory: true,
                size: 0, allocated: 0, modified: Date()));
        continue
    }
    scan.entries.append(
        DiskEntry(
            url: URL(fileURLWithPath: "\(base)/d\(dirs)/file-\(i).bin"), identity: .init(device: 1, inode: UInt64(i)), directory: false, size: 4096,
            allocated: 4096, modified: Date()))
}
struct FixtureRandom: RandomNumberGenerator {
    var state: UInt64 = 42
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1; return state }
}
var random = FixtureRandom()
scan.entries.shuffle(using: &random)
let f0 = residentMB()
var t = now()
let tree = UsageTree(scan)
let treeTime = now() - t
precondition(tree.nodes.count == n + 1 && tree.nodes[0].files == n - dirs)
precondition(tree.nodes[0].logical == Int64(n - dirs) * 4096)
print(String(format: "UsageTree(%d entries): %.2f s, RSS +%.0f MB (nodes %d)", n, treeTime, residentMB() - f0, tree.nodes.count))
fflush(stdout)
if ProcessInfo.processInfo.environment["DISK_BENCHMARK_CONTROLS"] != "0" {
    t = now()
    _ = scan.entries.sorted { $0.url.path < $1.url.path }
    let s1 = now() - t
    t = now()
    let keyed = scan.entries.map { ($0.url.path, $0) }.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
    let s2 = now() - t
    print(String(format: "sort by url.path per comparison: %.2f s; precomputed utf8 keys: %.2f s (%d)", s1, s2, keyed.count))
}
