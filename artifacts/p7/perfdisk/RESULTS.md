# W-136 — disk utilities and utility-window CPU

Owner: porpoise-perfdisk. Base: 9e234a3. Product commits: 1fe4044, 7cf5675, 3dcfe19, b194234, ac221b3.

Status: complete. The P-8 target of about 1–2 seconds for 1M entries is met: **24.62 s -> 1.50 s (16.4× faster)** in the serialized run. APP-7 cancellation/latest-input and geometry-cache checks pass.

## Final acceptance evidence

All commands ran in this worktree on Apple M5 / 10 cores / macOS 27.0.1. Full watchdog and timings were serialized with `lockf -k /tmp/porpoise-gate.lock`; product prebuild ran separately at `-j 4` and drained before tests/timings. `locked-window.log` records the window and host load (38.51 initially, 11.52 at the end); these are individual same-fixture runs, not statistical medians or an idle-host claim.

| Probe | Before | After |
|---|---:|---:|
| UsageTree, fixed-seed 1M entries | 24.62 s | **1.50 s** |
| UsageTree RSS increase (decimal MB, not peak footprint) | 334 MB | **195 MB** |
| Cleanup matching, 1000 candidates × 1000 installed apps | 3594.63 ms | **8.04 ms** |
| Rename 10000 rows, synchronous work on main vs scheduling 3 edits | 415.09 ms | **0.186 ms** |

The rename comparison measures main-thread blocking/scheduling, not total preview completion latency; the probe then waits for and checks the latest result. APP-7 had no numeric report target. Diff work comparison: a completed 100k-line diff took **139.94 ms**; a superseded request stopped at checkpoint 20 in **1.13 ms**. This is cancellation work avoided, not old/new algorithm throughput. Raw results: locked-before.log, locked-after.log, locked-cleanup-before.log, locked-cleanup-after.log, locked-diff.log, locked-ui.log.

- `swift build -c release --product Porpoise -j 4`: passed, `RELEASE_EXIT=0`, 309.40 s (release-final.log).
- `PORPOISE_DENY_KEYCHAIN_DYLIB=... TEST_TIMEOUT=900 ./scripts/test-with-watchdog.sh -j 4`: passed, `WATCHDOG_EXIT=0` (watchdog-final.log). Resource pass: 6 tests. Main pass: Services 936, HelperKit 31, FileSystem 123 with 1 existing known issue, Core 214, App 42 (1346 main-pass tests). The tripwire activated; no denial was emitted. Bundled static ffmpeg and checksum-verified search tools were present.
- `PORPOISE_DISK_BENCHMARK=1 ... ./scripts/test-with-watchdog.sh -j 4 --filter UtilityPerformance`: 3 tests passed, `UI_EXIT=0` (locked-ui.log).
- `swift format lint --strict -r Sources/PorpoiseCore Sources/PorpoiseServices Sources/Porpoise Sources/PorpoiseHelper Tests`: passed, empty format-lint.log. `git diff --check` and `bash -n Benchmarks/DiskUtilities/run.sh` passed.

`final-gates.log` records release=0, watchdog=0, baseline=0, optimized=0, ui=0. The exact locked command script is archived as locked-gates.sh; benchmark compilation commands are in the benchmark README. No CI, attended UI, or real-account probing is claimed.

Changes:

- UsageTree builds a directory-only path index, assigns lexical hard-link owners independent of arrival order, links arbitrary-order parents, and aggregates directories in postorder. No whole-file path sort or retained file-path dictionary.
- PhysicalTreeScanner returns traversal order. DuplicateFinder chooses hard-link representatives without sorting, buckets sizes before hashing, and releases identity/singleton bookkeeping before content reads. Checksums retain their visible lexical order via cached keys at the presentation boundary.
- App Cleanup prepares exclusive ownership/name/group matching once per scan/revalidation, reads each main application's signature once, and streams candidate size totals through TreeMeasure without retaining/building a full UsageTree. Shared ownership, exact identifiers, conservative errors, symlink/volume policy and Trash revalidation remain covered.
- Batch Rename debounces 150 ms and serializes cancellable planning off main. Editing disables Rename immediately; only the current input/snapshot generation can publish. Superseded work and close cancel planning; only this dialog's own modal session is stopped.
- File Diff uses a serial per-window diff queue and per-generation cancellation through line splitting/normalization, patience/Myers matching, word differences and presentation rows. Existing nonthrowing APIs remain compatible. Closing cancels reads and CPU work.
- Treemap caches geometry by current items/bounds and indexes item IDs for label lookup. Label formatting remains limited to label-sized tiles.

Reproduction: [benchmark driver and instructions](/Users/daniel/Projects/porpoise/.hteam/worktrees/porpoise-perfdisk/Benchmarks/DiskUtilities/README.md). Benchmarks use Core source compiled with swiftc -O; app UI scheduling/caching probes use the debug test target and offscreen bitmaps. No onscreen FPS/UI acceptance is claimed.

## Exploratory runs (unserialized; host contention)

Initial same-size random-shuffle fixture: UsageTree 1M entries **26.23 s / +328 MB RSS -> 0.93 s / +195 MB RSS** (before.log / after.log).

The fixed-seed rerun overlapped multiple builds/full suites; host load reached 72.78 on 10 cores and contaminated wall time/RSS with paging: **40.85 s / +306 MB -> 14.71 s / +405 MB** (reproduce-before.log / reproduce-after.log). Its unchanged comparator control itself grew **85.28 -> 149.26 s**, confirming incompatible contention. This run is retained and is not the authoritative optimization ratio.

Cleanup: 1000 candidates / 1000 installed apps, one match both variants, including preparation: **25,980.91 -> 9.50 ms** (cleanup-before.log / cleanup-after.log).

Cancellation workload (current implementation, not an old/new throughput claim): completing a 100k-line text diff **999.56 ms**, superseding at checkpoint 20 **1.38 ms** (diff-benchmark.log).

## Earlier validation and setup findings

Initial focused disk/cleanup run: 17 Services + 9 Core tests passed. The first expanded focused build caught a missing test-support import, corrected before the full run.

First full watchdog (watchdog.log): resource pass 6 tests passed; Services 936 tests failed with 16 issues (15 due Homebrew ffmpeg's dylibs being denied by the production video sandbox, 1 OneDrive timing-ratio assertion under load). HelperKit 31 passed, FileSystem 123 passed with one known issue, Core 214 passed. App run did not produce a complete summary and is not claimed green. No Keychain denial was emitted.

The bundled static ffmpeg has since been rebuilt from scripts/build-ffmpeg.sh's pinned/checksummed source (ffmpeg-cache.log); only system dependencies remain. Final runs use it, the Keychain tripwire and fetched search tools. Per the lead's board #3166, final full watchdog and timed probes are serialized with lockf /tmp/porpoise-gate.lock. The final successful results are recorded above.

The standalone debug app probe subsequently passed all 3 UtilityPerformance tests (ui-benchmark.log): 10000-row synchronous preview **1539.03 ms** vs **0.186 ms** to schedule three input changes on main, then latest-result publication verified. This compares main-thread stall/scheduling, not total preview latency. Treemap geometry reused across four repaints and invalidated by bounds/items; presentation cancellation stopped at the expected checkpoint. The dialog close helper exposed stopping an unrelated/nonexistent modal session; 3dcfe19 guards it by the dialog's actual modal window.

The generic release command failed in PorpoiseServicesTestSupport because its @testable dependency was not built for testing, after release Core/FS/Services compilation (release-build.log). The final release check explicitly builds `swift build -c release --product Porpoise -j 4`, which excludes that test-support target.
