# M4 fast transfers and previews (W-70)

## Behavior

- Binary files at least 32 MiB download into a private, preallocated job partial with four to eight size-adaptive ranged requests. A 300 MiB file uses five streams. Small files retain the existing six-job batch path.
- Every range has its own fsynced journal offset. Interrupted ranges restart at those offsets; completed ranges issue no request. The partial is published only after the existing MD5 and fresh revision/head/size checks.
- Preview consumers check the shared full-copy cache first. A cold image/document shows its thumbnail before the verified full rendition. Text/code can first show a bounded 64 KiB prefix.
- Audio/video use a selection-owned loopback range proxy with a random secret path. Upstream credentials remain in Drive transport. Reads are bounded to 1 MiB, use recorded binary revision URLs where available, and stop with selection/preview cancellation.
- The Information panel shows loading progress, buffering, and errors. Space previews use AVPlayer for cloud media; Quick Look retains local file URLs for image/document renditions. Apple's `previewItemURL` contract requires file URLs: https://developer.apple.com/documentation/quicklook/qlpreviewitem/previewitemurl.
- Streamed ranges are transient; the shared offline store remains the only full binary-copy cache. Warm full previews make no request. Streaming does not create a second persistent full-copy cache.

## Measurements (fake server only)

Command: `PORPOISE_TRANSFER_BENCHMARK=1 swift test --filter DriveParallelDownloadTests.perConnectionThroughput`

300 MiB, 50 ms latency, 40 Mbps per response, 400 Mbps aggregate:

| Mode | Seconds | MiB/s |
| --- | ---: | ---: |
| Single stream | 64.403 | 4.658 |
| Parallel (five streams, maximum eight) | 13.569 | 22.109 |

Elapsed speedup: 4.75x. Both outputs passed MD5 verification. These are local synthetic results, not real-account throughput claims.

Command: `python3 scripts/benchmark-drive-upload.py`

64 MiB resumable upload, 100 Mbps payload cap, 50 ms per PUT:

| Chunk | Seconds | MiB/s |
| --- | ---: | ---: |
| 8 MiB | 6.520 | 9.816 |
| 32 MiB | 6.007 | 10.655 |

Keep the existing 8 MiB upload chunk: roughly 8% lower elapsed time in this model does not justify quadrupling request memory and the pause boundary. No real-account upload was attempted.

## Preview evidence

Final isolated latency-budget command:
`PORPOISE_PREVIEW_BENCHMARK=1 swift test --skip-build --filter 'DriveProgressivePreviewTests.firstThumbnailThenFullAndWarmViewMakesNoRequest|DriveStreamingPreviewTests.rangesAreBoundedSecretAndStopCancels'`

This passed both explicit 550 ms budgets: first image 427 ms and first range 387 ms, each with 300 ms server latency. Timing budgets are enforced in this isolated mode, rather than during the full suite's simultaneous CPU, subprocess, and main-actor stress. A loaded full-suite image measurement was 1.598 s; the isolated latency number is not a guarantee under arbitrary contention.

Commands: `swift test --filter 'DriveProgressivePreviewTests|DriveStreamingPreviewTests|DriveParallelDownloadTests'`

- First image thumbnail after the unified-store rebase: 427 ms at 300 ms server latency (127 ms overhead). Earlier runs measured 414–426 ms.
- AVPlayer actually advanced: final full replay 1.671 s, 1,048,578 of 67,108,864 bytes fetched (1.56%). The concurrent video-suite replay measured 1.550 s with the same byte count.
- First small byte range: 368 ms at 300 ms latency, 334 bytes.
- Warm full preview: request/byte statistics unchanged.
- Selection cancellation after the thumbnail: zero media bytes fetched.
- Stream stop cancels local/upstream requests; secret-path, HEAD, byte-range parsing, suffix/open-ended ranges, and existing loopback-only tests pass.
- Interrupted parallel resume requests exactly the missing suffixes; changed revisions and wrong checksums never mark the journal done.
- Text/code paints 65,536 bytes before the complete 131,072-byte file.

## Final gates

Validated on runtime/test head `67309f4`, rebased onto main `58ee691` (W-67/W-68/W-69 plus IconTheme locking). The final report commit changes documentation only.

| Gate | Command | Result |
| --- | --- | --- |
| Strict formatter | `swift format lint --strict -r Sources/PorpoiseCore Sources/PorpoiseServices Sources/Porpoise Sources/PorpoiseHelper Tests` | Exit 0, no output |
| Build | `swift build` | Exit 0 |
| Full watchdog | `PORPOISE_DENY_KEYCHAIN_DYLIB=/tmp/porpoise-fastpreview-deny-keychain.dylib scripts/test-with-watchdog.sh --enable-code-coverage` | Exit 0: Services 721, Core 338, AppKit 4; all 1,063 passed |
| Coverage | `python3 scripts/coverage.py --min 92` immediately after that full run | Exit 0: 92.7% of 23,720 logic-layer lines |
| Whitespace | `git diff --check` | Exit 0 |
| Search prerequisites | `scripts/fetch-search-tools.sh` | fd and rg fetched before coverage validation |

Additional integrated replay: 19 tests passed, covering the new previews, parallel ranges, cached opens, small copies, and W-68's 200-file offline reconciliation. The concurrent Drive/VideoPreview replay passed 28 tests. Every test run used fake accounts; final watchdog and video overlap runs enabled the Keychain-denial tripwire.

The first full replay found a test fixture reading the mutable `VideoPreview.testFFmpeg` override. The corrected fixture uses the immutable real ffmpeg path and remuxes the checked-in H.264 clip, requiring no optional encoder. The next full replay hit the pre-existing hdiutil ENOTEMPTY fixture failure plus a fake-phone disappearance timeout; both passed isolated rerun. The final complete replay passed all tests, including those cases, without exclusions or increased timeouts.

UI build, layout tests, and real AVPlayer transport proofs are distinct from attended mouse/keyboard or screenshot acceptance, which was not performed. No real Google account, operator preferences, or operator Porpoise process was accessed or changed. Streamed ranges are not persisted as a second full-file cache.
