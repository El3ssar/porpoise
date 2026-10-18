# File-job performance benchmark

Build the same optimized benchmark against a revision without changing the checkout's manifest:

```sh
python3 scripts/benchmark-file-jobs.py --revision 9e234a3
python3 scripts/benchmark-file-jobs.py --revision HEAD
```

Each command prints its executable path. To measure uncommitted tracked source changes, add `--working-tree`.
Snapshots and their build output stay under `.build/perfjobs/`. The baseline snapshot receives declarations
for the point-check capability and a no-op Trash flush only when absent; its transfer/Trash implementation
stays unchanged. The fake path server implements the same capability on both revisions, ignored by the old engine.

Run each executable with the same inputs and settings:

```sh
PerfBench verify <original-folder> <copy-folder>
PerfBench checksum <folder>
PerfBench move <source-tree> <destination-folder-on-the-same-volume>
PerfBench trash 10000 500
PerfBench remote <scratch-root> 500
```

Verification samples physical footprint inside a single long GCD work item, every 20 ms. The workload used
for W-134 is 100 files of 10 MiB each (1,000 MiB total), compared with an identical copy. Checksums use those
same files. The move tree has 310 directories containing 1,000 empty files each (310,311 entries including
its root). Move it back between repetitions; do not regenerate it inside the timed region.

Trash records 500 new origins into an isolated UserDefaults domain seeded with 10,000 entries, and reports
record time separately from the batch flush and prune. Its paths are synthetic; no actual Trash operation runs.
The remote workload copies 500 seven-byte files through an isolated filesystem-backed provider and reports
destination listing, staging-directory and final live point-check counts. This measures algorithmic work,
not network throughput. Production SSH and adb use point checks; FTP retains its final authoritative listing.

Run timing workloads sequentially and record host load. Shared-machine times are not latency guarantees.
The regression suites check cancellation, conflicting arrivals, cleanup, Undo, batched persistence and
single-file retained-memory bounds. The streaming regression shares the serialized `MemoryBudgetTests`
suite and runs in the watchdog's isolated first pass.
