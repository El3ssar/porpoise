These probes compile only the Core sources they exercise, with `swiftc -O`. Run from the repository root.

```
Benchmarks/DiskUtilities/run.sh 9e234a3  # P7 baseline
Benchmarks/DiskUtilities/run.sh          # current implementation
```

The million-entry fixture follows the SERVICES sweep: 1000 directories, 999000 files, long cache paths, shuffled traversal order. The archived driver adds a fixed PRNG seed (42) and asserts node/file/byte totals. The first timing measures UsageTree alone; subsequent comparator timings are independent controls. RSS is `mach_task_basic_info.resident_size`, decimal MB; it is not peak physical footprint. `DISK_BENCHMARK_COUNT` overrides the entry count. Shared-host load can substantially change wall times.

Other probes:

```
mkdir -p .build/perfdisk/cleanup
# Old matching implementation, same harness/fixture:
git show 9e234a3:Sources/PorpoiseCore/AppCleanup/AppCleanupRules.swift > .build/perfdisk/cleanup/Rules.swift
swiftc -O -D BASELINE .build/perfdisk/cleanup/Rules.swift Benchmarks/DiskUtilities/cleanup.swift -o .build/perfdisk/cleanup-before
.build/perfdisk/cleanup-before
swiftc -O Sources/PorpoiseCore/AppCleanup/AppCleanupRules.swift Benchmarks/DiskUtilities/cleanup.swift -o .build/perfdisk/cleanup-after
.build/perfdisk/cleanup-after

swiftc -O Sources/PorpoiseCore/FileComparison/TextDifference.swift Benchmarks/DiskUtilities/diff.swift -o .build/perfdisk/diff-benchmark
.build/perfdisk/diff-benchmark
PORPOISE_DISK_BENCHMARK=1 ./scripts/test-with-watchdog.sh --filter UtilityPerformance
```

Cleanup measures 1000 candidates against 1000 installed applications, including matcher construction; both variants assert one match. Diff compares a completed 100k-line diff with a superseded request stopping at checkpoint 20; this is a cancellation-work comparison, not an old/new algorithm throughput comparison. The app probe uses 10000 synthetic snapshot rows and compares synchronous preview work with scheduling three input changes on main, then verifies the latest result. Its default 200-row mode is the correctness test. Treemap tests render into an offscreen bitmap and assert cache reuse/invalidation; no onscreen latency/FPS is inferred.
