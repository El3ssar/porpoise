# W-134: file-job performance

Measured 2026-10-18 on Apple M5, macOS 27.0.1, APFS. Baseline: `9e234a3`.
The before and after batches each held `lockf /tmp/porpoise-gate.lock` for every timed command.
Other workers' builds were permitted concurrently; load averages at batch start were 32.85 and 30.27.
These are shared-host measurements, not latency guarantees. Footprint values use MiB (the sweep driver labels them MB).

| Workload | Before | After |
|---|---:|---:|
| Verify 100 × 10 MiB files, physical footprint sampled inside one GCD work item | 2,012 MB peak; 3.05 s | 5 MB peak; 1.99 s |
| Checksum those 100 files, footprint retained before outer work item ends | 1,007 MB peak/end; 1.20 s | 3 MB peak/end; 0.82 s |
| Same-volume move of a 310,311-entry tree: Preparing | 16.13 s | 0.01 s |
| Same move: total | 16.14 s | 0.01 s |
| Trash origins: 500 per-item records, initially 10,000 keys | 54.80 ms/item; 27.40 s | 0.02 ms/item; 0.01 s |
| Additional batch flush after the 500 records | writes already included above | 42.1 ms |
| Fake path-server copy of 500 seven-byte files | 16.655 s | 0.602 s |
| Destination listings / stage folders for that batch | 501 / 500 | 1 / 1 |
| Live point checks before remote publication | 0 (fresh listings instead) | 500 |

Both remote batches completed all 500 files with zero errors. The baseline listing count is measured,
rather than the sweep report's estimate of two listings per file. Synthetic Trash prune/drain time was
32.5 ms before and 82.7 ms after; production pruning now runs on its utility queue. The after benchmark
explicitly waits for it with `flush()`. No item in the actual Trash is touched by this benchmark.

## Changes and behavior checks

- Drain hash/read/byte-compare buffers per chunk, including a single large file. Read failures cannot produce
  a digest of partial data. Verification observes cancellation between chunks; Resume restarts verification
  of the completed copies, and a cancelled verification is not recorded as successful.
- Skip deep inventory only for a same-volume move whose destination does not exist. Recheck before transfer,
  recovering full inventory when a destination or mount changed. Existing conflict, copy, merge, cross-volume,
  cancellation, staging and Undo paths remain covered. Rename-only selections count as one item with zero
  transferred bytes; conflicts/cross-volume paths retain full inventory counts. Copy staging reuses the path-length inventory; merge
  children drain their pools, and Keep Both reuses a folder-name cache with filesystem collision checks.
- Trash origins are shared in memory immediately, with coalesced writes, off-main pruning and explicit job,
  Undo and quit flushes. Owned-item unlocks use no-follow syscalls off main; job-finished notification waits
  for the unlock retry. A recursive unlock leaves an external symlink target unchanged.
- Path transfers index destination names and share a hidden staging folder per destination directory.
  SSH and adb retain a live final existence check; providers without point checks retain a fresh listing.
  Repeated names reload authoritative destination metadata, so conflict rules do not assume uploads preserve
  source dates. Cancellation/failure cleanup and recoverable replacement stages remain protected.
  The cloud transfer journal/opaque-ID engine is unchanged.

## Reproduction and verification

See [README.md](README.md) for the build driver, workload sizes and commands. The benchmark source is the
same on both revisions; baseline-only compatibility declarations do not change its production algorithms.

Focused validation under the Keychain-denial tripwire:

- 67 Services tests passed: Activity, file comparison, Trash ledger, remote conflict parity, transfer
  cancellation/rollback, SSH, FTP and adb behavior, and the first path-cache regression cases.
- Final focused run: 23 Delete/Trash disk-image tests plus 3 FileJob performance regressions passed.
- The first run of the new rename regression compared directory URLs with different trailing-slash spelling.
  Its content/Undo checks passed; the corrected path comparison passes in the final run.

- Production release: `swift build -c release --product Porpoise -j 2` passed (327.93 s).
- Strict lint: `swift format lint --strict -r Sources/PorpoiseCore Sources/PorpoiseServices Sources/Porpoise Sources/PorpoiseHelper Tests` passed with no output.
  Separate strict lint of both changed FileSystem files and the benchmark source also passed with no output.
- Test prebuild: `swift build --build-tests -j 2` passed (11.98 s).
- Streaming memory regression: `PORPOISE_TESTS_ALONE=1 swift test --skip-build --filter streamingReadsReleaseChunksBeforeTheWorkItemEnds` passed (1 test, 0.253 s), with the Keychain-denial tripwire.
- Final remote cache/fallback regressions: `swift test --skip-build --filter RemoteTransferPerformanceTests` passed (3 tests, including 4 arrival/cancellation cases, 0.243 s), with the same tripwire.
- The lead dropped worker full watchdogs in board #3233 and will run one consolidated gate after integration.
  The gate opened during cancellation of this worker's queued job; its child briefly ran and was stopped too.
  Its partial log recorded 15 video-probe/codec/duration/software-output/playability issues in `VideoPreviewTests.swift`.
  Those failures are untriaged and reported to the lead; no worker full-suite success is claimed.

An unqualified `swift build -c release -j 2` failed in the existing `PorpoiseServicesTestSupport` target's
`@testable import PorpoiseServices`; the production release gate uses `--product Porpoise` to exclude test support.
